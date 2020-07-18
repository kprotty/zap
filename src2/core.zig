const std = @import("std");

pub const Scheduler = extern struct {
    pub const ScheduleFn = fn(*Node, ScheduleType, usize) callconv(.C) bool;

    pub const ScheduleType = extern enum {
        spawn_worker,
        resume_thread,
    };
    
    nodes: Node.Cluster,
    nodes_active: usize,
    schedule_fn: ScheduleFn,
};

pub const Node = extern struct {
    next: *Node,
    scheduler: *Scheduler,
    workers_ptr: [*]Worker,
    workers_len: u16,
    runq_stub: ?*Task,
    runq_tail: usize,
    runq_head: *Task,
    idle_queue: usize,
    threads_active: usize,
    
};

pub const Worker = extern struct {
    ptr: usize,

    const Ref = union(enum) {
        worker: ?*Worker,
        node: *Node,
        thread: *Thread,
        handle: Thread.Handle,

        fn encode(self: Ref) usize {
            return switch (self) {
                .worker => |ptr| @ptrToInt(ptr) | 0,
                .node => |ptr| @ptrToInt(ptr) | 1,
                .thread => |ptr| @ptrToInt(ptr) | 2,
                .handle => |ptr| @ptrToInt(ptr) | 3,
            };
        }

        fn decode(value: usize) Ref {
            const ptr = value & ~@as(usize, 0b11);
            return switch (value & 0b11) {
                0 => Ref{ .worker = @intToPtr(?*Worker, ptr) },
                1 => Ref{ .node = @intToPtr(*Node, ptr) },
                2 => Ref{ .thread = @intToPtr(*Thread, ptr) },
                3 => Ref{ .handle = @intToPtr(Thread.Handle, ptr) },
                else => unreachable,
            };
        }
    };
};

pub const Thread = extern struct {
    pub const Handle = ?*const u32;

    prng: u16,
    next: usize,
    worker: ?*Worker,
    node: *Node,
    handle: Handle,
    runq_next: ?*Task,
    runq_head: usize,
    runq_tail: usize,
    runq_buffer: [256]*Task,

    pub fn init(
        noalias self: *Thread,
        noalias worker: *Worker,
        handle: Handle,
    ) void {
        const worker_ptr = @atomicLoad(usize, &worker.ptr, .Acquire);
        const node = switch (Worker.Ref.decode(worker_ptr)) {
            .node => |node| node,
            else => |worker_ref| std.debug.panic("Invalid worker ref {} on Thread.init()", .{worker_ref}),
        };

        self.* = Thread{
            .prng = @truncate(u16, (@ptrToInt(node) ^ @ptrToInt(self)) >> 16),
            .next = undefined,
            .worker = worker,
            .node = node,
            .handle = handle,
            .runq_next = null,
            .runq_head = 0,
            .runq_tail = 0,
            .runq_buffer = undefined,
        };

        const worker_ref = Worker.Ref{ .thread = self };
        @atomicStore(usize, &worker.ptr, worker_ref.encode(), .Release);
    }

    pub fn deinit(noalias self: *Thread) void {
        const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        const tail = @atomicLoad(usize, &self.runq_tail, .Monotonic);
        const next = @atomicLoad(?*Task, &self.runq_next, .Monotonic);

        if (self.worker != null)
            std.debug.panic("Thread.deinit() before shutdown", .{});
        if (next != null)
            std.debug.panic("Thread.deinit() with pending runq next {*}", .{next});
        if (tail != head)
            std.debug.panic("Thread.deinit() with {} pending runq tasks", .{tail -% head });
    }

    pub fn poll(noalias self: *Thread) bool {
        const worker = self.worker orelse return false;
        const node = self.node;
        var is_waking = true;

        while (true) {
            var polled_node = false;
            const next_task = blk: {
                if (self.pollSelf()) |task| {
                    break :blk task;
                }

                var nodes = node.iter();
                while (nodes.next()) |target_node| {
                    if (self.pollNode(target_node)) |task| {
                        polled_node = true;
                        break :blk task;
                    }

                    var prng = self.prng;
                    prng ^= prng << 7;
                    prng ^= prng >> 9;
                    prng ^= prng << 8;
                    self.prng = prng;

                    const workers = target_node.workers_ptr;
                    const num_workers = target_node.workers_len;
                    var worker_index = prng % num_workers;

                    var worker_iter = num_workers;
                    while (worker_iter != 0) : (worker_iter -= 1) {
                        const current_index = worker_index;
                        worker_index = if (worker_index == num_workers - 1) 0 else (worker_index + 1);
                        const target_worker = &workers[current_index];
                        
                        const target_worker_ptr = @atomicLoad(usize, &target_worker.ptr, .Acquire);
                        switch (Worker.Ref.decode(target_worker_ptr)) {
                            .worker, .node => {},
                            .handle => std.debug.panic("Worker {} with thread handle set when stealing", .{current_index}),
                            .thread => |target_thread| {
                                if (target_thread == self)
                                    continue;
                                if (self.pollThread(target_thread)) |task|
                                    break :blk task;
                            }
                        }
                    }
                }

                break :blk null;
            };

            if (next_task) |task| {
                if (is_waking or polled_node)
                    node.tryResumeThread(.{ .was_waking = is_waking });
                
                is_waking = false;
                task.run(self);
                continue;
            }

            if (node.trySuspendThread(self, is_waking)) |status| {
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
        while (true) {
            const size = tail -% head;
            if (size == 0)
                break;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.pollSelf() with invalid runq size {}", .{size}); 

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

    fn pollThread(
        noalias self: *Thread,
        noalias target: *Thread,
    ) ?*Task {
        const tail = self.runq_tail;
        const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        if (tail != head)
            std.debug.panic("Thread.pollThread() with non-empty ({}) runq", .{tail -% head});
        
        var target_head = @atomicLoad(usize, &target.runq_head, .Acquire);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.runq_tail, .Acquire);
            const target_size = target_tail -% target_head;
            if (target_size > target.runq_buffer.len)
                std.debug.panic("Thread.pollThread() with invalid target runq size {}", .{target_size});

            var steal = target_size - (target_size / 2);
            if (steal == 0) {
                const target_next = @atomicLoad(?*Task, &target.runq_next, .Monotonic) orelse return null;
                _ = @cmpxchgWeak(
                    ?*Task,
                    &target.runq_next,
                    target_next,
                    null,
                    .Acquire,
                    .Monotonic,
                ) orelse return target_next;
                continue;
            }

            steal -= 1;
            var new_tail = tail;
            var new_target_head = target_head +% 1;
            const first_task = target.runq_buffer[target_head % target.runq_buffer.len];

            while (steal != 0) : (steal -= 1) {
                const task = target.runq_buffer[new_target_head % target.runq_buffer.len];
                self.runq_buffer[new_tail % self.runq_buffer.len] = task;
                new_target_head +%= 1;
                new_tail +%= 1;
            }

            if (@cmpxchgWeak(
                usize,
                &target.runq_head,
                target_head,
                new_target_head,
                .Release,
                .Acquire,
            )) |updated_target_head| {
                target_head = updated_target_head;
                continue;
            }

            if (tail != new_tail)
                @atomicStore(usize, &self.runq_tail, new_tail, .Release);
            return first_task;
        }
    }

    fn pollNode(
        noalias self: *Thread,
        noalias node: *Node,
    ) ?*Task {
        var runq_tail = @atomicLoad(usize, &node.runq_tail, .Monotonic);
        while (true) {
            if (runq_tail & 1 != 0)
                return null;
            runq_tail = @cmpxchgWeak(
                usize,
                &node.runq_tail,
                runq_tail,
                runq_tail | 1,
                .Acquire,
                .Monotonic,
            ) orelse break;
        }

        
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
                    
                    if (@cmpxchgWeak(
                        ?*Task,
                        &self.runq_next,
                        next,
                        task,
                        .Release,
                        .Monotonic,
                    )) |new_runq_next| {
                        runq_next = new_runq_next;
                        continue;
                    };

                    task = next;
                    break;
                }
            }

            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            while (true) {
                const size = new_tail -% head;
                if (size > self.runq_buffer.len)
                    std.debug.panic("Thread.schedule() with invalid runq size {}", .{size}); 

                if (size < self.runq_buffer.len) {
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

        pub fn isEmpty(self: Batch) bool {
            return self.head == null;
        }

        pub fn pushFront(noalias self: *Batch, noalias task: *Task) void {
            return self.pushFrontMany(Batch.from(task));
        }

        pub fn pushBack(noalias self: *Batch, noalias task: *Task) void {
            return self.pushBackMany(Batch.from(task));
        }

        pub fn pushFrontMany(self: *Batch, batch: Batch) void {
            const batch_head = batch.head orelse return;
            if (self.head) |head| {
                batch.tail.next = head;
                self.head = batch_head;
            } else {
                self.* = batch;
            }
        }

        pub fn pushBackMany(self: *Batch, batch: Batch) void {
            const batch_head = batch.head orelse return;
            if (self.head) |head| {
                self.tail.next = batch_head;
                self.tail = batch.tail;
            } else {
                self.* = batch;
            }
        }

        pub fn iter(self: Batch) Iter {
            return Iter.from(self.head);
        }
    };

    pub const Iter = extern struct {
        task: ?*Task = null,

        fn from(task: ?*Task) Iter {
            return Iter{ .task = task };
        }

        pub fn next(self: *Iter) ?*Task {
            const task = self.task orelse return null;
            self.task = task.next;
            return task;
        }
    }
};
