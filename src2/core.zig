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
};

pub const Thread = extern struct {
    pub const Id = *const u16;

    pub const Slot = extern struct {
        ptr: usize,
    };

    id: Id,
    next: usize,
    state: usize,
    slot: *Slot,
    node: *Node,
    scheduleFn: ScheduleFn,
    runq_next: ?*Task,

    pub fn init(
        noalias self: *Thread,
        noalias slot: *Slot,
        id: Id,
    ) void {
        const node = @intToPtr(*Node, @atomicLoad(usize, &slot.ptr, .Acquire));
        
        self.* = Thread{
            .id = id,
            .next = undefined,
            .state = 0,
            .slot = slot,
            .node = node,
            .runq_next = null,
        };

        @atomicStore(usize, &slot.ptr, @ptrToInt(self) | 1, .Release);
    }

    pub fn deinit(noalias self: *Thread) void {

    }

    pub const Status = extern enum {
        Shutdown = 0,
        Suspend = 1,
    };

    pub fn poll(
        noalias self: *Thread,
        spawn_fn: fn(*Slot) callconv(.C) bool,
        resume_fn: fn(*Thread) callconv(.C) void,
    ) Status {

    }

    fn tryPollTask(
        noalias self: *Thread,
        noalias node: *Node,
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
                if (@atomicLoad(?*Task, &self.runq_next, .Monotonic) != null) { 
                    task = @atomicRmw(?*Task, &self.runq_next, .Xchg, task, .Release) orelse continue :next_task;
                } else {
                    @atomicStore(?*Task, &self.runq_next, task, .Release);
                    continue :next_task;
                }
            }

            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            push_task: while (true) {
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
                    continue :push_task;
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
