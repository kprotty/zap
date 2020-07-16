const std = @import("std");

pub const Scheduler = extern struct {
    pub const ScheduleFn = fn(*Node, ScheduleType, usize) callconv(.C) bool;

    pub const ScheduleType = extern enum {
        slot,
        thread,
    };
    
    nodes: Node.Cluster,
    nodes_active: usize,
    schedule_fn: ScheduleFn,
};

pub const Node = extern struct {
    next: *Node,
    scheduler: *Scheduler,
    slots_ptr: [*]Thread.Slot,
    slots_len: u16,
    idle_queue: usize,
    threads_active: usize,

    fn trySuspendThread(
        noalias self: *Node,
        noalias thread: *Thread,
        state: Thread.State,
        sched_tick: u8,
        prng: u16,
    ) ?Thread.Status {
        const slot = thread.slot;
        const slot_index = blk: {
            const offset = @ptrToInt(slot) - @ptrToInt(self.slots_ptr);
            break :blk (offset / @sizeOf(Thread.Slot));
        };

        thread.prng = prng;
        thread.state = .suspended;
        thread.sched_tick = sched_tick;

        var idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
        while (true) {
            var tags = @truncate(u8, idle_queue);
            var aba_tag = @truncate(u8, idle_queue >> 8);
            var index = @truncate(u16, idle_queue >> 16);

            var notified = false;
            if (state == .waking or index == 0) {
                if (idle_queue & IDLE_NOTIFIED != 0) {
                    tags &= ~@as(u8, IDLE_NOTIFIED);
                    notified = true;
                }
            }

            if (!notified) {
                thread.next = index;
                index = slot_index + 1;
            }

            const new_idle_queue = 
                (@as(u32, index) << 16) |
                (@as(u32, aba_tag +% 1) << 8) |
                tags;

            if (@cmpxchgWeak(
                usize,
                &node.idle_queue,
                idle_queue,
                new_idle_queue,
                .Release,
                .Monotonic,
            )) |new_idle_queue| {
                idle_queue = new_idle_queue;
                continue;
            }

            if (notified) {
                thread.state = state;
                return null;
            }

            const threads_active = @atomicRmw(usize, &self.threads_active, .Sub, 1, .AcqRel);
            if (threads_active == 1) {
                const scheduler = self.scheduler;
                const nodes_active = @atomicRmw(usize, &scheduler.nodes_active, .Sub, 1, .AcqRel);
                if (nodes_active == 1) {
                    self.shutdown(scheduler, thread);
                    return .Shutdown;
                }
            }

            return .Suspended;
        }
    }

    fn shutdown(
        noalias self: *Node,
        noalias scheduler: *Scheduler,
        noalias initiator: *Thread,
    ) void {

    }
};

pub const Thread = extern struct {
    pub const Id = *const u16;

    pub const Slot = extern struct {
        ptr: usize,
    };

    const State = enum(u8) {
        shutdown,
        suspended,
        waking,
        running,
    };
    
    prng: u16,
    state: State,
    sched_tick: u8,
    next: usize,
    slot: *Slot,
    node: *Node,
    id: Id,
    runq_next: ?*Task,
    runq_head: usize,
    runq_tail: usize,
    runq_buffer: [256]*Task,

    pub fn init(slot: *Slot, id: Id) Thread {
        const node = @intToPtr(*Node, @atomicLoad(usize, &slot.ptr, .Acquire));
        return Thread{
            .prng = @truncate(u16, (@ptrToInt(node) ^ @ptrToInt(self)) >> 16),
            .state = .waking,
            .sched_tick = 0,
            .next = undefined,
            .slot = slot,
            .node = node,
            .id = id,
            .runq_next = null,
            .runq_head = 0,
            .runq_tail = 0,
            .runq_buffer = undefined,
        };
    }

    pub const Status = extern enum {
        Shutdown = 0,
        Suspend = 1,
    };

    pub fn poll(noalias self: *Thread) Status {
        const node = self.node;
        var prng = self.prng;
        var state = self.state;
        var sched_tick = self.sched_tick;
        @atomicStore(usize, &slot.ptr, @ptrToInt(self) | 1, .Release);

        while (true) {
            var polled_node = false;
            const next_task = blk: {

                if (sched_tick % 61 == 0) {
                    if (self.pollNode(node)) |task| {
                        polled_node = true;
                        break :blk task;
                    }
                }

                if (self.pollSelf()) |task| {
                    break :blk task;
                }

                var nodes = node.iter();
                while (nodes.next()) |target_node| {
                    if (self.pollNode(target_node)) |task| {
                        polled_node = true;
                        break :blk task;
                    }

                    prng ^= prng << 7;
                    prng ^= prng >> 9;
                    prng ^= prng << 8;
                    const slots = target_node.slots_ptr;
                    const num_slots = target_node.slots_len;

                    var slot_iter = num_slots;
                    var slot_index = prng % num_slots;
                    while (slot_iter != 0) : (slot_iter -= 1) {
                        const slot = &slots[slot_index];
                        slot_index += 1;
                        if (slot_index == num_slots)
                            slot_index = 0;

                        const ptr = @atomicLoad(usize, &slot.ptr, .Acquire);
                        if (ptr & 1 == 0)
                            continue;

                        const target_thread = @intToPtr(*Thread, ptr);
                        if (target_thread == self)
                            continue;

                        if (self.pollThread(target_head)) |task| {
                            break :blk task;
                        }
                    }


                    if (self.pollNode(target_node)) |task| {
                        polled_node = true;
                        break :blk task;
                    }
                }

                break :blk null;
            };

            if (next_task) |task| {
                if (state == .waking) {
                    node.tryResumeThread(.{ .was_waking = true });
                } else if (polled_node) {
                    node.tryResumeThread(.{});
                }
                
                state = .running;
                sched_tick +%= 1;
                task.run(self);
                continue;
            }

            if (node.trySuspendThread(self, state, prng, tick)) |status| {
                return status;
            }
        }
    }

    fn pollSelf(
        noalias self: *Thread,
    ) ?*Task {
        var runq_next = @atomicLoad(?*Task, &self.runq_next, .Monotonic);
        while (runq_next) |next| {
            runq_next = @cmpxchgWeak(
                ?*Task,
                &self.runq_next,
                next,
                null,
                .Monotonic,
                .Monotonic,
            ) orelse return next;
        }

        const tail = self.runq_tail;
        var head = @atomicStore(usize, &self.runq_head, .Monotonic);
        while (tail != head) {
            head = @cmpxchgWeak(
                usize,
                &self.head,
                head,
                head +% 1,
                .Monotonic,
                .Monotonic,
            ) orelse return self.runq_buffer[head % self.runq_buffer.len];
        }

        return null;
    }

    fn pollNode(
        noalias self: *Thread,
        noalias node: *Node,
    ) ?*Task {

    }

    fn pollThread(
        noalias self: *Thread,
        noalias target: *Thread,
    ) ?*Task {

    }

    pub fn schedule(noalias self: *Thread, batch: Batch) void {
        var tasks = batch;
        const node = self.node;
        const tail = self.runq_tail;
        var new_tail = tail;

        next_task: while (true) {
            var task = tasks.pop() orelse break;
            const priority = task.getPriority();

            if (priority == .lifo) {
                var runq_next = @atomicLoad(?*Task, &self.runq_next, .Monotonic);
                while (true) {
                    const next = runq_next orelse blk: {
                        @atomicStore(?*Task, &self.runq_next, task, .Release);
                        break :next_task;
                    };
                    runq_next = @cmpxchgWeak(
                        ?*Task,
                        &self.runq_next,
                        next,
                        task,
                        .Release,
                        .Monotonic,
                    ) orelse {
                        task = next;
                        break;
                    };
                }
            }

            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            while (true) {
                if (new_tail -% head < self.runq_buffer.len) {
                    self.runq_buffer[new_tail % self.runq_buffer.len] = task;
                    new_tail +%= 1;
                    continue :next_task;
                }

                var migrate: usize = self.runq_buffer.len / 2;
                if (@cmpxchgWeak(
                    usize,
                    &self.runq_head,
                    head,
                    head +% migrate,
                    .Monotonic,
                    .Monotonic,
                )) |new_head| {
                    head = new_head;
                    continue;
                }

                var overflowed = Task.Batch{};
                while (migrate != 0) : (migrate -= 1) {
                    overflowed.pushBack(self.runq_buffer[head % self.runq_buffer.len]);
                    head +%= 1;
                }

                if (priority == .fifo)
                    tasks.pushFront(task);
                overflowed.pushBackMany(tasks);
                if (priority == .lifo)
                    overflowed.pushFront(task);

                tasks = overflowed;
                break :next_task;
            }
        }

        if (new_tail != tail)
            @atomicStore(usize, &self.runq_tail, new_tail, .Release);
        if (!tasks.isEmpty())
            node.pushBack(tasks);

        node.tryResumeThread(.{});
    }
};

pub const Task = extern struct {
    pub const Callback = fn(*Task, *Thread) callconv(.C) void;

    pub const Priority = extern enum {
        fifo = 0,
        lifo = 1,
    };

    next: ?*Task,
    data: usize,

    pub fn init(priority: Priority, callback: Callback) Task {
        return Task{
            .next = undefined,
            .data = @ptrToInt(callback) | @enumToInt(priority),
        };
    }

    pub fn getPriority(self: Task) Priority {
        return switch (@truncate(u1, self.data)) {
            0 => Priority.fifo,
            1 => Priority.lifo,
            else => unreachable,
        };
    }

    pub fn run(noalias self: *Task, noalias thread: *Thread) void {
        const callback = @intToPtr(Callback, self.data & ~@as(usize, 1));
        return (callback)(self, thread);
    }

    pub const Batch = extern struct {
        head: ?*Task,
        tail: *Task,

        pub fn init() Batch {
            return Batch{
                .head = null,
                .tail = undefined,
            };
        }

        pub fn from(task: *Task) Batch {
            task.next = null;
            return Batch{
                .head = task,
                .tail = task,
            };
        }

        pub fn pushFront(noalias self: *Batch, noalias task: *Task) void {
            return self.pushFrontMany(Batch.from(task));
        }

        pub fn pushBack(noalias self: *Batch, noalias task: *Task) void {
            return self.pushBackMany(Batch.from(task));
        }

        pub fn pushFrontMany(self: *Batch, batch: Batch) void {

        }
    };
};
