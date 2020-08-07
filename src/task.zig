const std = @import("std");

pub const Task = extern struct {
    next: ?*Task,
    callback: CallbackFn,

    pub const CallbackFn = fn(
        *Task,
        *Thread,
    ) callconv(.C) void;

    pub const Batch = extern struct {
        head: ?*Task = null,
        tail: *Task = undefined,

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

        pub fn push(noalias self: *Batch, noalias task: *Task) void {
            return self.pushBack(task);
        }

        pub fn pop(noalias self: *Batch) ?*Task {
            return self.popBack();
        }

        pub fn pushFront(noalias self: *Batch, noalias task: *Task) void {
            return self.pushFrontMany(Batch.from(task));
        }
        
        pub fn pushBack(noalias self: *Batch, noalias task: *Task) void {
            return self.pushBackMany(Batch.from(task));
        }

        pub fn popBack(noalias self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }

        pub fn pushFrontMany(self: *Batch, batch: Batch) void {
            if (batch.isEmpty()) {
                return;
            } else if (self.isEmpty()) {
                self.* = batch;
            } else {
                batch.tail.next = self.head;
                self.head = batch.head;
            }
        }

        pub fn pushBackMany(self: *Batch, batch: Batch) void {
            if (batch.isEmpty()) {
                return;
            } else if (self.isEmpty()) {
                self.* = batch;
            } else {
                self.tail.next = batch.head;
                self.tail = batch.tail;
            }
        }

        pub fn iter(self: Batch) Iter {
            return Iter{ .task = self.head };
        }

        pub const Iter = extern struct {
            task: ?*Task,

            pub fn next(noalias self: *Iter) ?*Task {
                const task = self.task orelse return null;
                self.task = task.next;
                return task;
            }
        };
    };

    const CACHE_ALIGN = switch (std.builtin.arch) {
        .x86_64 => 64 * 2,
        .i386, .arm, .aarch64 => 64,
        else => @alignOf(usize), 
    };

    pub const Scheduled = union(enum) {
        spawned: *Worker,
        resumed: *Thread,
    };

    pub const Thread = extern struct {
        runq_head: usize,
        runq_tail: usize,
        runq_overflow: ?*Task,
        runq_buffer: [256]*Task align(CACHE_ALIGN),
        ptr: usize,
        worker: *Worker,
        id: Id,

        pub const Id = ?*align(@alignOf(Worker)) c_void;

        pub fn init(
            noalias self: *Thread,
            noalias worker: *Worker,
            id: Id,
        ) void {
            const ptr = @atomicLoad(usize, &worker.ptr, .Monotonic);
            const scheduler = switch (Worker.Ref.fromUsize(ptr)) {
                .worker => std.debug.panic("Thread.init() with worker that hasnt been spawned yet", .{}),
                .thread => std.debug.panic("Thread.init() with worker that is already associated with a thread", .{}),
                .scheduler => |scheduler| scheduler,
                .id => std.debug.panic("Thread.init() with worker thats already shutdown", .{}),
            };

            self.* = Thread{
                .runq_head = 0,
                .runq_tail = 0,
                .runq_overflow = null,
                .runq_buffer = undefined,
                .ptr = @ptrToInt(scheduler),
                .worker = worker,
                .id = id,
            };

            const worker_ref = Worker.Ref{ .thread = self };
            @atomicStore(usize, &worker.ptr, worker_ref.toUsize(), .Release);
        }

        pub fn deinit(self: *Thread) void {
            defer self.* = undefined;

            const size = self.runq_tail -% @atomicLoad(usize, &self.runq_head, .Monotonic);
            if (size != 0)
                std.debug.panic("Thread.deinit() when runq not empty with size of {}", .{size});

            const runq_overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
            if (runq_overflow != null)
                std.debug.panic("Thread.deinit() when runq overflow not empty", .{});  
        }

        pub fn push(noalias self: *Thread, tasks: Batch) void {
            var batch = tasks;
            var tail = self.runq_tail;
            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);

            while (true) {
                var size = tail -% head;
                if (size > self.runq_buffer.len)
                    std.debug.panic("Thread.push() with invalid runq size of {}", .{size});

                if (size < self.runq_buffer.len) {
                    var new_tail = tail;
                    while (size < self.runq_buffer.len) : (size += 1) {
                        const task = batch.pop() orelse break;
                        self.runq_buffer[new_tail % self.runq_buffer.len] = task;
                        new_tail +%= 1;
                    }

                    if (new_tail != tail) {
                        tail = new_tail;
                        @atomicStore(usize, &self.tail, tail, .Release);
                    }
                        
                    if (batch.isEmpty())
                        return;
                    head = @atomicLoad(usize, &self.runq_head, .Monotonic);
                    continue;
                }

                const new_head = head +% (self.runq_buffer.len / 2);
                if (@cmpxchgWeak(
                    usize,
                    &self.head,
                    head,
                    new_head,
                    .AcqRel,
                    .Monotonic,
                )) |updated_head| {
                    head = updated_head;
                    continue;
                }

                var overflowed = Batch{};
                while (head != new_head) : (head +%= 1) {
                    const task = self.runq_buffer[head % self.runq_buffer.len];
                    overflowed.pushBack(task);
                }

                batch.pushFrontMany(overflowed);
                var runq_overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
                while (true) {
                    batch.task.next = runq_overflow;

                    if (runq_overflow == null) {
                        @atomicStore(?*Task, &self.runq_overflow, batch.head, .Release);
                        return;
                    }

                    runq_overflow = @cmpxchgWeak(
                        ?*Task,
                        &self.runq_overflow,
                        runq_overflow,
                        batch.head,
                        .Release,
                        .Monotonic,
                    ) orelse return;
                }
            }
        }

        fn inject(noalias self: *Thread, noalias runq_overflow: ?*Task, tail: usize) void {
            var runq = runq_overflow;
            var size = tail -% @atomicLoad(usize, &self.runq_head, .Monotonic); 
            if (size != 0)
                std.debug.panic("Thread.inject() when non empty runq with size of {}", .{size});

            var new_tail = tail;
            while (size < self.runq_buffer.len) : (size += 1) {
                const task = runq orelse break;
                self.runq_buffer[new_tail % self.runq_buffer.len] = task;
                new_tail +%= 1;
            }

            if (new_tail != tail)
                @atomicStore(usize, &self.runq_tail, new_tail, .Release);
            if (runq != null)
                @atomicStore(?*Task, &self.runq_overflow, runq, .Release);
        } 

        pub fn pop(self: *Thread) ?*Task {
            const tail = self.runq_tail;
            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);

            while (true) {
                const size = tail -% head;
                if (size > self.runq_buffer.len)
                    std.debug.panic("Thread.pop() with invalid runq size of {}", .{size});

                if (size > 0) {
                    head = @cmpxchgWeak(
                        usize,
                        &self.runq_head,
                        head,
                        head +% 1,
                        .Monotonic,
                        .Monotonic,
                    ) orelse return self.runq_buffer[head % self.runq_buffer.len];
                    continue;
                }

                var runq_overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
                while (true) {
                    const first_task = runq_overflow orelse return null;
                    runq_overflow = @cmpxchgWeak(
                        ?*Task,
                        &self.runq_overflow,
                        runq_overflow,
                        null,
                        .Monotonic,
                        .Monotonic,
                    )) orelse {
                        self.inject(first_task.next, tail);
                        return first_task;
                    };
                }                
            }
        }

        pub fn stealFromScheduler(noalias self: *Thread, noalias scheduler: *Scheduler) ?*Task {
            var runq = @atomicLoad(?*Task, &scheduler.runq, .Monotonic);
            while (true) {
                const first_task = runq orelse return null;
                runq = @cmpxchgWeak(
                    ?*Task,
                    &scheduler.runq,
                    null,
                    .Acquire,
                    .Monotonic,
                ) orelse {
                    self.inject(first_task.next, self.runq_tail);
                    return first_task;
                };
            }
        }

        pub fn stealFromThread(noalias self: *Thread, noalias target: *Thread) ?*Task {
            const tail = self.runq_tail;
            const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            const size = tail -% head;

            const overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
            if (size != 0 or overflow != null)
                std.debug.panic("Thread.stealFrom() when runq not empty with size of {} and overflow {*}", .{size, overflow});

            var target_head = @atomicLoad(usize, &target.runq_head, .Acquire);
            while (true) {
                const target_tail = @atomicLoad(usize, &target.runq_tail, .Acquire);
                const target_size = target_tail -% target_head;

                if (target_size > self.runq_buffer.len) {
                    target_head = @atomicLoad(usize, &target.runq_head, .Acquire);
                    continue;
                }

                var grab = target_size - (target_size / 2);
                if (grab == 0) {
                    const first_task = @atomicLoad(?*Task, &target.runq_overflow, .Monotonic) orelse return null;
                    if (@cmpxchgWeak(
                        ?*Task,
                        &target.runq_overflow,
                        first_task,
                        null,
                        .Acquire,
                        .Monotonic,
                    )) |_| {
                        target_head = @atomicLoad(usize, &target.runq_head, .Acquire);
                        continue;
                    }
                    self.inject(first_task.next, tail);
                    return first_task;
                }

                grab -= 1;
                var new_target_head = target_head +% 1;
                const first_task = target.runq_buffer[target_head % target.runq_buffer.len];

                var new_tail = tail;
                while (grab != 0) : (grab -= 1) {
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
                    .Acquire,
                    .Acquire,
                )) |updated_target_head| {
                    target_head = updated_target_head;
                    continue;
                }

                if (new_tail != tail)
                    @atomicStore(usize, &self.runq_tail, new_tail, .Release);
                return first_task;
            }
        }
    };

    pub const Worker = extern struct {
        ptr: usize align(2),

        const RefType = enum(u2) {
            worker = 0,
            thread = 1,
            scheduler = 2,
            id = 3,
        };

        const Ref = union(RefType) {
            worker: ?*Worker,
            thread: *Thread,
            scheduler: *Scheduler,
            id: Thread.Id,

            fn fromUsize(value: usize) Ref {
                const ptr = value & ~@as(usize, 0b11);
                return switch (value & 0b11) {
                    0 => Ref{ .worker = @intToPtr(?*Worker, ptr) },
                    1 => Ref{ .thread = @intToPtr(*Thread, ptr) },
                    2 => Ref{ .scheduler = @intToPtr(*Scheduler, ptr) },
                    3 => Ref{ .id = @intToPtr(?*Thread.Id, ptr) },
                    else => unreachable,
                }
            }

            fn toUsize(self: Ref) usize {
                return switch (self) {
                    .worker => |ptr| @ptrToInt(ptr) | 0,
                    .thread => |ptr| @ptrToInt(ptr) | 1,
                    .scheduler => |ptr| @ptrToInt(ptr) | 2,
                    .id => |ptr| @ptrToInt(ptr) | 3,
                };
            }
        };

        pub fn getThread(self: *const Worker) ?*Thread {
            const ptr = @atomicLoad(usize, &self.ptr, .Acquire);
            return switch (Ref.fromUsize(ptr)) {
                .worker, .scheduler => null,
                .thread => |thread| thread,
                .id => std.debug.panic("Worker.getThread() when worker already shutdown", .{}),
            };
        }

        pub fn getThreadId(self: *const Worker) ThreadId {
            const ptr = @atomicLoad(usize, &self.ptr, .Acquire);
            return switch (Ref.fromUsize(ptr)) {
        }
    };

    pub const Scheduler = extern struct {
        workers_ptr: [*]Worker,
        workers_len: usize,
        runq: ?*Task align(CACHE_ALIGN),
        idle_queue: usize align(CACHE_ALIGN),
        active_threads: usize,

        pub fn init(noalias self: *Scheduler, workers: []Worker) void {
            var idle_queue: usize = 0;

            self.* = Scheduler{
                .workers_ptr = workers.ptr,
                .workers_len = workers.len,
                .runq = null,
                .idle_queue = idle_queue,
                .active_threads = 0,
            };
        }

        pub fn deinit(self: *Scheduler) void {
            defer self.* = undefined;

            const idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
            if (idle_queue != IDLE_SHUTDOWN)
                std.debg.panic("Scheduler.deinit() when not shutdown", .{});

            const runq = @atomicLoad(?*Task, &self.runq, .Monotonic);
            if (runq != null)
                std.debug.panic("Scheduler.deinit() when runq not empty", .{});

            const active_threads = @atomicLoad(usize, &self.active_threads, .Monotonic);
            if (active_threads != 0)
                std.debug.panic("Scheduler.deinit() with {} active threads", .{active_threads});
        }

        pub fn getWorkers(self: Scheduler) []Worker {
            return self.workers_ptr[0..self.workers_len];
        }

        pub fn push(self: *Scheduler, tasks: Batch) void {
            const head = tasks.head orelse return;
            const tail = tasks.tail;
            var runq = @atomicLoad(?*Task, &self.runq, .Monotonic);

            while (true) {
                tail.next = runq;
                runq = @cmpxchgWeak(
                    ?*Task,
                    &self.runq,
                    runq,
                    head,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }
        }

        pub fn tryResume(self: *Scheduler, was_waking: bool) ?Scheduled {

        }

        pub fn trySuspend(noalias self: *Scheduler, noalias thread: *Thread) ?bool {

        }

        pub fn shutdown(self: *Scheduler) SuspendedThreadIter {
            
        }

        pub const SuspendedThreadIter = extern struct {
            head: ?*Thread = null,
            tail: *Thread = undefined,

            fn push(noalias self: *SuspendedThreadIter, noalias thread: *Thread) void {
                @atomicStore(usize, &thread.ptr, @ptrToInt(self.head), .Unordered);
                if (self.head == null)
                    self.tail = thread;
                self.head = thread;
            }

            pub fn next(self: *SuspendedThreadIter) ?*Thread {
                const thread = self.head orelse return null;
                const thread_ptr = @atomicLoad(usize, &thread.ptr, .Unordered);
                self.head = @intToPtr(?*Thread, thread_ptr);
                return thread;
            }
        };
    };
};

