// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.


const std = @import("std");

pub const Task = struct {
    next: ?*Task,
    frame: anyframe,

    pub fn init(frame: anyframe) Task {
        return Task{
            .next = undefined,
            .frame = frame,
        };
    }

    pub fn getCurrentThread() *Thread {
        return Thread.getCurrent() orelse {
            std.debug.panic("Task.getCurrentThread() from outside the Thread", .{});
        };
    }

    pub fn spawn(allocator: *std.mem.Allocator, comptime func: anytype, args: anytype) !void {
        const Args = @typeOf(args);
        const Wrapper = struct {
            fn entry(self: *@Frame(func), func_args: Args, allocator: *std.mem.Allocator) void {
                var task = Task.init(@frame());
                suspend task.schedule();

                _ = @call(.{}, func, func_args);

                suspend allocator.destroy(self);
            }
        };

        const frame = try allocator.create(@Frame(func));
        frame.* = Wrapper.entry(frame, args, allocator);
    }

    pub fn schedule(self: *Task) void {
        return Batch.from(self).schedule();
    }

    pub fn scheduleNext(self: *Task) void {
        const thread = getCurrentThread();

        if (thread.runq_next) |old_task|
            thread.schedule(Batch.from(old_task));

        thread.runq_next = self;
    }

    pub fn yield() void {
        const thread = getCurrentThread();

        if (self.runq_next == null) {
            const next_task = thread.poll() orelse return;
            self.runq_next = next_task;
        }

        var task = Task.init(@frame());
        suspend thread.schedule(Batch.from(&task));
    }

    pub fn callBlocking(comptime func: anytype, args: anytype) @TypeOf(func).ReturnType {
        var task: Task = undefined;

        const pool = getCurrentThread().getPool();
        const blocking_pool = pool.getBlockingPool();
        const was_blocking = pool == blocking_pool;

        if (!was_blocking) {
            task = Task.init(@frame());
            suspend blocking_pool.schedule(Batch.from(&task));
        }

        const result = @call(.{}, func, args);

        if (!was_blocking) {
            task = Tatsk.init(@frame());
            suspend pool.schedule(Batch.from(&task));
        }

        return result;
    }

    pub const Batch = struct {
        head: ?*Task = null,
        tail: *Task = undefined,

        pub fn isEmpty(self: Batch) bool {
            return self.head == null;
        }

        pub fn from(task: *Task) Batch {
            task.next = null;
            return Batch{
                .head = task,
                .tail = task,
            };
        }

        pub fn push(self: *Batch, task: *Task) void {
            return self.pushBack(task);
        }

        pub fn pushBack(self: *Batch, task: *Task) void {
            return self.pushBackMany(from(task));
        }

        pub fn pushFront(self: *Batch, task: *Task) void {
            return self.pushFrontMany(from(task));
        }

        pub fn pushBackMany(self: *Batch, other: Batch) void {
            if (other.isEmpty())
                return;
            if (self.isEmpty()) {
                self.* = other;
            } else {
                self.tail.next = other.head;
                self.tail = other.tail;
            }
        }

        pub fn pushFrontMany(self: *Batch, other: Batch) void {
            if (other.isEmpty())
                return;
            if (self.isEmpty()) {
                self.* = other;
            } else {
                other.tail.next = self.head;
                self.head = other.head;
            }
        }

        pub fn pop(self: *Batch) ?*Task {
            return self.popFront();
        }

        pub fn popFront(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }

        pub fn schedule(self: Batch) void {
            const thread = Task.getCurrentThread();
            thread.schedule(self);
        }
    };

    pub fn runAsync(comptime func: anytype, args: anytype) !@TypeOf(func).ReturnType {
        const Args = @TypeOf(args);
        const ReturnType = @TypeOf(func).ReturnType;

        const Wrapper = struct {
            fn entry(func_args: Args, task_ptr: *Task, result_ptr: *?Result) void {
                suspend task_ptr.* = Task.init(@frame());
                const result = @call(.{}, func, func_args);
                suspend result_ptr.* = result;
            }
        };

        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.entry(args, &task, &result);

        try runTask(&task);

        return result orelse error.DeadLocked;
    }

    pub fn run(self: *Task) !void {
        const num_threads = 
            if (std.builtin.single_threaded) 1
            else std.Thread.cpuCount() catch 1;

        const stack_workers = (std.mem.page_size / 2) / @sizeOf(Worker);
        if (num_threads <= stack_workers) {
            var workers: [stack_workers]Worker = undefined;
            return Scheduler.runUsing(workers[0..]);
        }

        const allocator = std.heap.page_allocator;
        const workers = try allocator.alloc(Worker, num_threads);
        defer allocator.free(workers);
        return Scheduler.runUsing(workers);
    }

    const Scheduler = struct {
        core_pool: Pool,
        blocking_pool: Pool,
        active_pools: usize,

        fn runUsing(workers: []Worker, task: *Task) !void {
            var _blocking_workers: [64]Worker = undefined;
            const blocking_workers = _blocking_workers[0..];

            var self: Scheduler = undefined;
            try self.core_pool.init(workers);
            try self.blocking_pool.init(blocking_workers);
            self.active_pools = 0;

            self.core_pool.push(Batch.from(task));
            self.core_pool.resumeThread(.{ .is_main_thread = true });

            self.core_pool.deinit();
            self.blocking_pool.deinit();

            const active_pools = @atomicLoad(usize, &self.active_pools, .Monotonic);
            if (active_pools != 0)
                std.debug.panic("Scheduler.deinit() with {} active pools", .{active_pools});
        }
    };

    pub const Pool = extern struct {
        workers_ptr: [*]Worker,
        workers_len: usize,
        run_queue: ?*Task,
        idle_queue: usize,
        active_threads: usize,

        const IDLE_MARKED = 1;
        const IDLE_SHUTDOWN = ~@as(usize, 0);

        fn init(self: *Pool, workers: []Worker, is_blocking: bool) !void {
            if (workers.len == 0)
                return error.EmptyWorkers;

            self.* = Pool{
                .workers_ptr = workers.ptr,
                .workers_len = (workers.len << 1) | @boolToInt(is_blocking),
                .run_queue = null,
                .idle_queue = 0,
                .active_threads = 0,
            };

            for (workers) |*worker, index| {
                const next_index = self.idle_queue >> 8;
                const idle_ptr = Worker.IdlePtr{ .worker = next_index };
                worker.ptr = Worker.Ptr{ .idle = idle_ptr };
                self.idle_queue = (index + 1) << 8;
            }
        }

        fn deinit(self: *Pool) void {
            defer self.* = undefined;

            const active_threads = @atomicLoad(usize, &self.active_threads, .Monotonic);
            if (active_threads != 0)
                std.debug.panic("Pool.deinit() with {} active threads", .{active_threads});

            const idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
            if (idle_queue != IDLE_SHUTDOWN)
                std.debug.panic("Pool.deinit() when not shutdown", .{});

            const run_queue = @atomicLoad(?*Task, &self.run_queue, .Monotonic);
            if (run_queue != null)
                std.debug.panic("Pool.deinit() when runq not empty", .{});

            for (workers) |*worker, index| {
                const ptr = @atomicLoad(usize, &worker.ptr, .Acquire);
                switch (Worker.Ptr.fromUsize(ptr)) {
                    .idle, .spawning, .running => {
                        std.debug.panic("Pool.deinit() when worker {} not shutdown", .{index});
                    },
                    .shutdown => |thread_handle| {
                        const handle = thread_handle orelse continue;
                        handle.wait();
                    },
                }
            }
        }

        fn isBlocking(self: Pool) bool {
            return (self.workers_len & 1) != 0;
        }

        fn getScheduler(self: *Pool) *Scheduler {
            if (self.isBlocking())
                return @fieldParentPtr(Scheduler, "blocking_pool", self);
            return @fieldParentPtr(Scheduler, "core_pool", self);
        }

        pub fn getCorePool(self: *Pool) *Pool {
            return &self.getScheduler().core_pool;
        }

        pub fn getBlockingPool(self: *Pool) *Pool {
            return &self.getScheduler().blocking_pool;
        }

        fn getWorkers(self: Pool) []Worker {
            return self.workers_ptr[0..(self.workers_len >> 1)];
        }

        const ResumeOptions = struct {
            is_main_thread: bool = false,
            is_waking: bool = false,
        };

        const ResumeType = union {
            spawn: *Worker,
            notify: *Thread,
        };

        fn resumeThread(self: *Scheduler, options: ResumeOptions) void {
            const workers = self.getWorkers();
            var idle_queue = @atomicLoad(usize, &self.idle_queue, .Acquire);

            while (true) {
                if (idle_queue == IDLE_SHUTDOWN)
                    std.debug.panic("Pool.resumeThread() when already shutdown", .{});

                if (!options.is_waking and (idle_queue & IDLE_MARKED != 0))
                    return;

                var worker_index = idle_queue >> 8;
                var aba_tag = @truncate(u8, idle_queue) >> 1;
                var new_resume_type: ?ResumeType = null;
                var new_idle_queue: usize = (aba_tag << 1) | IDLE_MARKED;

                if (worker_index != 0) {
                    const worker = &workers[worker_index - 1];
                    const ptr = @atomicLoad(usize, &worker.ptr, .Acquire);
                    switch (Worker.Ptr.fromUsize(ptr)) {
                        .idle => |idle_ptr| switch (idle_ptr) {
                            .worker => |next_index| {
                                new_idle_queue |= next_index << 8;
                                new_resume_type = ResumeType{ .spawn = worker };
                            },
                            .thread => |thread| {
                                const next_index = @atomicLoad(usize, &thread.ptr, .Unordered);
                                new_idle_queue |= next_index << 8;
                                new_resume_type = ResumeType{ .notify = thread };
                            },
                        },
                        .spawning, .running => {
                            std.SpinLock.loopHint(1);
                            idle_queue = @atomicLoad(usize, &self.idle_queue, .Acquire);
                            continue;
                        },
                        .shutdown => {
                            std.debug.panic("Pool.resumeThread() when worker {} shutdown", .{worker_index - 1});
                        },
                    }
                }

                if (@cmpxchgWeak(
                    usize,
                    &self.idle_queue,
                    idle_queue,
                    new_idle_queue,
                    .Acquire,
                    .Acquire,
                )) |updated_idle_queue| {
                    idle_queue = updated_idle_queue;
                    continue;
                }

                var active_threads = @atomicRmw(usize, &self.active_threads, .Add, 1, .Monotonic);
                if (active_threads == 0)
                    _ = @atomicRmw(usize, &self.getScheduler().active_pools, .Add, 1, .Monotonic);

                const worker = blk: switch (resume_type) {
                    .spawn => |worker| {
                        const spawn_info = Thread.SpawnInfo{
                            .pool = self,
                            .worker = worker_index - 1,
                        };

                        if (options.is_main_thread)
                            return Thread.run(spawn_info);

                        const handle = std.Thread.spawn(spawn_info, Thread.run) catch break :blk worker;
                        const idle_ptr = IdlePtr{ .worker = new_idle_queue >> 8 };
                        const worker_ptr = @cmpxchgStrong(
                            usize,
                            &worker.ptr,
                            (Worker.Ptr{ .idle = idle_ptr }).toUsize(),
                            (Worker.Ptr{ .spawning = handle }).toUsize(),
                            .AcqRel,
                            .Acquire,
                        ) orelse return;

                        switch (Worker.Ptr.fromUsize(worker_ptr)) {
                            .idle => |idle_ptr| switch (idle_ptr) {
                                .worker => {
                                    std.debg.panic("Pool.resumeThread() spawning worker {} when idle", .{worker_index - 1});
                                },
                                .thread => |thread| {
                                    thread.handle = handle;
                                    return;
                                },
                            },
                            .running => |thread| {
                                thread.handle = handle;
                                return;
                            },
                            .spawning => {
                                std.debug.panic("Pool.resumeThread() spawning worker {} when already spawning", .{worker_index - 1});
                            },
                            .shutdown => {
                                std.debug.panic("Pool.resumeThread() spawning worker {} when already shutdown", .{worker_index - 1});
                            },
                        }
                    },
                    .notify => |thread| {
                        if (options.is_main_thread)
                            std.debug.panic("Pool.resumeThread() waking worker {} thread when is_main_thread", .{worker_index - 1});

                        const thread_ptr = @ptrToInt(self) | @boolToInt(options.is_waking);
                        @atomicStore(usize, &thread.ptr, thread_ptr, .Unordered);

                        return thread.event.set();
                    }
                };

                active_threads = @atomicRmw(usize, &self.active_threads, .Sub, 1, .AcqRel);
                if (active_threads == 1)
                    _ = @atomicRmw(usize, &self.getScheduler().active_pools, .Sub, 1, .Monotonic);

                idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
                while (true) {
                    if (idle_queue == IDLE_SHUTDOWN)
                        std.debug.panic("Pool.undoResumeThread() when already shutdown", .{});

                    next_index = idle_queue >> 8;
                    aba_tag = @truncate(u7, idle_queue >> 1);

                    const idle_ptr = Worker.IdlePtr{ .worker = next_index };
                    const worker_ptr = Worker.Ptr{ .idle = idle_ptr };
                    @atomicStore(usize, &worker.ptr, worker_ptr.toUsize(), .Unordered);

                    idle_queue = @cmpxchgWeak(
                        usize,
                        &self.idle_queue,
                        idle_queue,
                        (aba_tag +% 1) | (worker_index << 8),
                        .Release,
                        .Monotonic,
                    ) orelse return;
                }
            }
        }

        fn suspendThread(noalias self: *Pool, noalias thread: *Thread) void {
            @compileError("TODO");
        }

        fn push(self: *Pool, batch: Batch) void {
            if (batch.isEmpty())
                return;

            var run_queue = @atomicLoad(?*Task, &self.run_queue, .Monotonic);
            while (true) {
                batch.tail.next = run_queue;

                run_queue = @cmpxchgWeak(
                    ?*Task,
                    &self.run_queue,
                    run_queue,
                    batch.head,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }
        }

        pub fn schedule(self: *Pool, batch: Batch) void {
            self.push(batch);
            self.resumeThread(.{});
        }
    };

    const Worker = struct {
        ptr: usize,

        const IdlePtr = union {
            worker: usize,
            thread: *align(8) Thread,

            fn fromUsize(value: usize) IdlePtr {
                if (value & 0b100 != 0)
                    return IdlePtr{ .worker = value >> 3 };
                return IdlePtr{ .thread = @intToPtr(*align(8) Thread, value & ~@as(usize, 0b111)) };
            }

            fn toUsize(self: IdlePtr) usize {
                return switch (self) {
                    .worker => |index| (index << 3) | 0b100,
                    .thread => |thread| @ptrToInt(thread),
                };
            }
        };

        const PtrType = enum {
            idle = 3,
            spawning = 2,
            running = 1,
            shutdown = 0,
        };

        const Ptr = union(PtrType) {
            idle: IdlePtr,
            spawning: *align(4) std.Thread,
            running: *align(4) Thread,
            shutdown: ?*align(4) std.Thread,

            fn fromUsize(value: usize) Ptr {
                const ptr = value & ~@as(usize, 0b11);
                return switch (value & 0b11) {
                    3 => Ptr{ .idle = IdlePtr.fromUsize(value) },
                    2 => Ptr{ .spawning = @intToPtr(*align(4) Pool, ptr) },
                    1 => Ptr{ .running = @intToPtr(*align(4) Thread, ptr) },
                    0 => Ptr{ .shutdown = @intToPtr(?*align(4) std.Thread, ptr) },
                };
            }

            fn toUsize(self: Ptr) usize {
                return switch (self) {
                    .idle => |ptr| ptr.toUsize() | 3,
                    .spawning => |ptr| @ptrToInt(ptr) | 2,
                    .running => |ptr| @ptrToInt(ptr) | 1,
                    .shutdown => |ptr| @ptrToInt(ptr) | 0,
                };
            }
        };
    };

    const Thread = struct {
        runq_head: usize,
        runq_tail: usize,
        runq_overflow: ?*Task,
        runq_buffer: [256]*Task,
        runq_next: ?*Task,
        event: std.ResetEvent,
        handle: ?*std.Thread,
        ptr: usize,
        worker: usize,
        prng: usize,

        threadlocal var current: ?*Thread = null;

        fn getCurrent() ?*Thread {
            return current;
        }

        const SpawnInfo = struct {
            pool: *Pool,
            worker: usize,
        };

        fn run(spawn_info: SpawnInfo) void {
            const pool = spawn_info.pool;
            const worker = spawn_info.worker;

            var self = Thread{
                .runq_head = 0,
                .runq_tail = 0,
                .runq_overflow = null,
                .runq_buffer = undefined,
                .event = std.ResetEvent.init(),
                .handle = null,
                .ptr = @ptrToInt(pool),
                .worker = worker,
                .prng = (@ptrToInt(&self) ^ 13) ^ (@ptrToInt(pool) ^ 31),
            };

            const old_current = Thread.currnet;
            Thread.current = &self;
            defer Thread.current = old_current;

            var worker_ptr = (Worker.Ptr{ .running = &self }).toUsize();
            worker_ptr = @atomicRmw(usize, &worker.ptr, .Xchg, worker_ptr, .AcqRel);
            switch (Worker.Ptr.fromUsize(worker_ptr)) {
                .idle => |idle_ptr| switch (idle_ptr) {
                    .worker => {},
                    .thread => {
                        std.debug.panic("Thread.run() on worker {} who is idle with a thread", .{worker});
                    },
                },
                .spawning => |handle| {
                    self.handle = handle;
                }
                .running => {
                    std.debug.panic("Thread.run() on worker {} who is already running", .{worker});
                },
                .shutdown => {
                    std.debug.panic("Thread.run() on worker {} who is already shutdown", .{worker});
                },
            }

            while (true) {
                if (self.poll()) |new_task| {
                    var task = new_task;

                    var direct_yields: usize = 0;
                    while (direct_yields < 7) : (direct_yields += 1) {
                        self.runq_next = null;
                        task.run();
                        task = self.runq_next orelse break;
                    }

                    if (self.runq_next != null) {
                        self.runq_next = null;
                        self.schedule(Batch.from(task));
                    }

                    continue;
                }

                pool.suspendThread(&self);
                if ((self.ptr & ~@as(usize, 1)) != @ptrToInt(pool))
                    break;                
            }

            const runq_tail = self.runq_tail;
            const runq_head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            const runq_size = runq_tail -% runq_head;
            if (runq_size > self.runq_buffer.len)
                std.debug.panic("Thread.deinit() on worker {} when runq buffer has invalid size of {}", .{worker, runq_size});
            if (runq_size != 0)
                std.debug.panic("Thread.deinit() on worker {} when runq buffer not empty with size of {}", .{worker, runq_size});

            const runq_overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
            if (runq_overflow != null)
                std.debug.panic("Thread.deinit() on worker {} when runq overflow not empty", .{worker});

            self.event.deinit();
            return;
        }

        pub fn getPool(self: *Thread) *Pool {
            return @intToPtr(*Pool, self.ptr & ~@as(usize, 1));
        }

        pub fn schedule(self: *Thread, batch: Batch) void {
            self.push(batch);
            self.getPool().resumeThread(.{});
        }

        fn readBuffer(self: *const Thread, index: usize) *Task {
            const ptr = &self.runq_buffer[index % self.runq_buffer.len];
            return @atomicLoad(*Task, ptr, .Unordered);
        }

        fn writeBuffer(self: *Thread, index: usize, task: *Task) void {
            const ptr = &self.runq_buffer[index % self.runq_buffer.len];
            return @atomicStore(*Task, ptr, task, .Unordered);
        }

        fn isBufferEmpty(self: *const Thread) bool {
            const tail = self.runq_tail;
            const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            const overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
            
            const size = tail -% head;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.isBufferEmpty() on worker {} with invalid runq size of {}", .{self.worker, size});
            
            return (size == 0) and (overflow == null);
        }

        fn push(self: *Thread, batch: Batch) void {
            var tasks = batch;
            var tail = self.runq_tail;
            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);

            while (!tasks.isEmpty()) {
                const size = tail -% head;
                if (size > self.runq_buffer.len)
                    std.debug.panic("Thread.push() on worker {} with invalid runq size of {}", .{self.worker, size});

                var remaining = self.runq_buffer.len - size;
                if (remaining > 0) {
                    while (remaining > 0) : (remaining -= 1) {
                        const task = tasks.pop() orelse break;
                        self.writeBuffer(tail, task);
                        tail +%= 1;
                    }

                    @atomicStore(usize, &self.runq_tail, tail, .Release);
                    head = @atomicLoad(usize, &self.runq_head, .Monotonic);
                    continue;
                }

                var migrate = size / 2;
                if (@cmpxchgWeak(
                    usize,
                    &self.runq_head,
                    head,
                    head +% migrate,
                    .Acquire,
                    .Monotonic,
                )) |updated_head| {
                    head = updated_head;
                    continue;
                }

                tasks.pushFrontMany(blk: {
                    var migrated = Batch{};
                    while (migrate > 0) : (migrate -= 1) {
                        const task = self.readBuffer(head);
                        migrated.push(task);
                        head +%= 1;
                    }
                    break :blk migrated;
                });

                var overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
                while (true) {
                    tasks.tail.next = overflow;

                    if (overflow == null) {
                        @atomicStore(?*Task, &self.runq_overflow, tasks.head, .Release);
                        break;
                    }

                    overflow = @cmpxchgWeak(
                        ?*Task,
                        &self.runq_overflow,
                        overflow,
                        tasks.head,
                        .Release,
                        .Monotonic,
                    ) orelse break;
                }

                std.debug.assert(tasks.isEmpty());
                return;
            }
        }

        fn poll(self: *Thread) ?*Task {
            var pushed = false;
            const ptr = self.ptr;
            const pool = @intToPtr(*Pool, ptr & ~@as(usize, 1));

            const task = self.pollTask(pool, &pushed) orelse return null;

            const is_waking = (ptr & 1) != 0;
            if (is_waking or pushed) {
                pool.resumeThread({ .is_waking = is_waking });
                @atomicStore(usize, &self.ptr, @ptrToInt(pool), .Unordered);
            }

            return task;
        }

        fn pollTask(
            self: *Thread,
            noalias pool *Pool,
            noalias pushed: *usize,
        ) ?*Task {
            if (self.pollLocal()) |task| {
                return task;
            }
            
            var index = blk: {
                var x = self.prng;
                switch (@typeInfo(usize).Int.bits) {
                    16 => {
                        xs ^= xs << 7;
                        xs ^= xs >> 9;
                        xs ^= xs << 8;
                    },
                    32 => {
                        x ^= x << 13;
                        x ^= x >> 17;
                        x ^= x << 5;
                    },
                    64 => {
                        x ^= x << 13;
                        x ^= x >> 7;
                        x ^= x << 17;
                    },
                    else => @compileError("Unsupported architecture"),
                }
                self.prng = x;
                break :blk x;
            };

            var iter: usize = 0;
            const workers = pool.getWorkers();
            while (iter < workers.len) : (iter += 1) {
                const worker_index = index;
                const worker = &workers[worker_index];
                index = if (index == workers.len - 1) 0 else (index +% 1);

                const worker_ptr = @atomicLoad(usize, &worker.ptr, .Acquire);
                switch (Worker.Ptr.fromUsize(worker_ptr)) {
                    .idle, .spawning => {},
                    .shutdown => {
                        std.debug.panic("Thread.poll() on worker {} when worker {} is shutdown", .{self.worker, worker_index});
                    },
                    .running => |thread| {
                        if (thread == self)
                            continue;
                        if (self.pollSteal(thread)) |task| {
                            pushed.* = self.isBufferEmpty();
                            return task;
                        }
                    },
                }
            }

            if (self.pollGlobal(pool)) |task| {
                pushed.* = self.isBufferEmpty();
                return task;
            }

            return null;
        }

        fn pollLocal(self: *Thread) ?*Task {
            var tail = self.runq_tail;
            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            while (true) {

                const size = tail -% head;
                if (size > self.runq_buffer.len)
                    std.debug.panic("Thread.pollLocal() on worker {} with invalid runq size of {}", .{self.worker, size});

                if (size == 0)
                    break;

                head = @cmpxchgWeak(
                    usize,
                    &self.runq_head,
                    head,
                    head +% 1,
                    .Acquire,
                    .Monotonic,
                ) orelse return self.readBuffer(head);
            }

            var overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
            while (true) {
                const task = overflow orelse break;

                if (@cmpxchgWeak(
                    ?*Task,
                    &self.runq_overflow,
                    overflow,
                    null,
                    .Acquire,
                    .Monotonic,
                )) |updated_overflow| {
                    overflow = updated_overflow;
                    continue;
                }

                self.inject(task.next);
                return task;
            }

            return null;
        }

        fn pollGlobal(noalias self: *Thread, noalias target: *Pool) ?*Task {
            var run_queue = @atomicLoad(?*Task, &target.run_queue, .Monotonic);
            while (true) {
                const task = run_queue orelse break;

                if (@cmpxchgWeak(
                    ?*Task,
                    &target.run_queue,
                    run_queue,
                    null,
                    .Acquire,
                    .Monotonic,
                )) |updated_run_queue| {
                    run_queue = updated_run_queue;
                    continue;
                }

                self.inject(task.next);
                return task;
            }

            return null;
        }

        fn pollSteal(noalias self: *Thread, noalias target: *Thread) ?*Task {
            var tail = self.runq_tail;
            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            var size = tail -% head;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.pollSteal() on worker {} with invalid runq size of {}", .{self.worker, size});
            if (size != 0)
                std.debug.panic("Thread.pollSteal() on worker {} with non-empty runq size of {}", .{self.worker, size});
        
            var target_head = @atomicLoad(usize, &target.runq_head, .Acquire);
            while (true) {
                const target_tail = @atomicLoad(usize, &target.runq_tail, .Acquire);

                size = target_tail -% target_head;
                if (size > self.runq_buffer.len) {
                    std.SpinLock.loopHint(1);
                    target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                    continue;
                }

                size = size - (size / 2);
                if (size == 0) {
                    const task = @atomicLoad(?*Task, &target.runq_overflow, .Monotonic) orelse break;

                    if (@cmpxchgWeak(
                        ?*Task,
                        &target.runq_overflow,
                        task,
                        null,
                        .Acquire,
                        .Monotonic,
                    )) |_| {
                        std.SpinLock.loopHint(1);
                        target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                        continue;
                    }

                    self.inject(task.next);
                    return task;
                }

                const first_task = target.readBuffer(target_head); 
                var new_target_head = target_head +% 1;
                var new_tail = tail;
                steal -= 1;

                while (steal > 0) : (steal -= 1) {
                    const task = target.readBuffer(new_target_head);
                    new_target_head +%= 1;
                    self.writeBuffer(new_tail, task);
                    new_tail +%= 1;
                }

                if (@cmpxchgWeak(
                    usize,
                    &target.head,
                    target_head,
                    new_target_head,
                    .AcqRel,
                    .Monotonic,
                )) |updated_target_head| {
                    target_head = updated_target_head;
                    continue;
                }

                if (new_tail != tail)
                    @atomicStore(usize, &self.runq_tail, new_tail, .Release);
                return first_task;
            }
        }

        fn inject(noalias self: *Task, noalias batch_head: ?*Task) void {
            var overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
            if (overflow != null)
                std.debug.panic("Thread.inject() on worker {} with non-empty runq overflow", .{self.worker});

            var tail = self.runq_tail;
            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            var size = tail -% head;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.inject() on worker {} with invalid runq size of {}", .{self.worker, size});
            if (size != 0)
                std.debug.panic("Thread.inject() on worker {} with non-empty runq size of {}", .{self.worker, size});

            var runq = batch_head;
            var new_tail = tail;
            while (size < self.runq_buffer.len) : (size += 1) {
                const task = runq orelse break;
                runq = task.next;
                self.writeBuffer(new_tail, task);
                new_tail +%= 1;
            }

            if (new_tail != tail) {
                @atomicStore(usize, &self.runq_tail, new_tail, .Release);
            }

            if (runq != null) {
                @atomicStore(?*Task, &self.runq_overflow, runq, .Release);    
            }
        }
    };
};