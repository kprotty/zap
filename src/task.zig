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

pub const Task = extern struct {
    next: ?*Task,
    callback: CallbackFn,

    pub const CallbackFn = fn(
        noalias *Task,
        noalias *Thread,
    ) callconv(.C) void;

    pub fn run(noalias self: *Task, noalias thread: *Thread) void {
        return (self.callback)(self, thread);
    }

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

    pub const Thread = extern struct {
        runq_head: usize align(@alignOf(Worker)),
        runq_tail: usize,
        runq_overflow: ?*Task,
        runq_buffer: [256]*Task align(CACHE_ALIGN),
        ptr: usize,
        worker: *Worker,
        id: Id,

        pub const Id = ?*align(4) c_void;

        pub fn init(
            noalias self: *Thread,
            noalias worker: *Worker,
            id: Id,
        ) void {
            const ptr = @atomicLoad(usize, &worker.ptr, .Monotonic);
            const pool = switch (Worker.Ref.fromUsize(ptr)) {
                .thread => std.debug.panic("Thread.init() with worker that is already associated with a thread", .{}),
                .worker => std.debug.panic("Thread.init() with worker that hasnt been spawned yet", .{}),
                .pool => |pool| pool,
                .id => std.debug.panic("Thread.init() with worker thats already shutdown", .{}),
            };

            self.* = Thread{
                .runq_head = 0,
                .runq_tail = 0,
                .runq_overflow = null,
                .runq_buffer = undefined,
                .ptr = @ptrToInt(pool),
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

            if (runq != null) {
                const overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
                if (overflow != null)
                    std.debug.panic("Thread.inject() when non empty runq overflow", .{});
                @atomicStore(?*Task, &self.runq_overflow, runq, .Release);
            }
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

        pub fn stealFromPool(noalias self: *Thread, noalias pool: *Pool) ?*Task {
            var runq = @atomicLoad(?*Task, &pool.runq, .Monotonic);
            while (true) {
                const first_task = runq orelse return null;
                runq = @cmpxchgWeak(
                    ?*Task,
                    &pool.runq,
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

            var target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
            while (true) {
                const target_tail = @atomicLoad(usize, &target.runq_tail, .Acquire);
                const target_size = target_tail -% target_head;

                if (target_size > self.runq_buffer.len) {
                    target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
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
                        target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
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
    };

    pub const Worker = extern struct {
        ptr: usize align(8),

        const RefType = enum(u2) {
            thread = 0,
            worker = 1,
            pool = 2,
            id = 3,
        };

        const Ref = union(RefType) {
            worker: usize,
            thread: *Thread,
            pool: *Pool,
            id: Thread.Id,

            fn fromUsize(value: usize) Ref {
                const ptr = value & ~@as(usize, 0b11);
                return switch (value & 0b11) {
                    0 => Ref{ .thread = @intToPtr(*Thread, ptr) },
                    1 => Ref{ .worker = ptr },
                    2 => Ref{ .pool = @intToPtr(*Pool, ptr) },
                    3 => Ref{ .id = @intToPtr(Thread.Id, ptr) },
                    else => unreachable,
                }
            }

            fn toUsize(self: Ref) usize {
                return switch (self) {
                    .thread => |ptr| @ptrToInt(ptr) | 0,
                    .worker => |ptr| @ptrToInt(ptr) | 1,
                    .pool => |ptr| @ptrToInt(ptr) | 2,
                    .id => |ptr| @ptrToInt(ptr) | 3,
                };
            }
        };

        pub fn getThread(self: *const Worker) ?*Thread {
            const ptr = @atomicLoad(usize, &self.ptr, .Acquire);
            return switch (Ref.fromUsize(ptr)) {
                .thread => |thread| thread,
                .worker, .pool => null,
                .id => std.debug.panic("Worker.getThread() when worker already shutdown", .{}),
            };
        }

        pub fn getThreadId(self: *const Worker) ThreadId {
            const ptr = @atomicLoad(usize, &self.ptr, .Acquire);
            return switch (Ref.fromUsize(ptr)) {
                .thread => std.debug.panic("Worker.getThreadId() while worker thread is running", .{}),
                .worker => std.debug.panic("Worker.getThreadId() when worker not shutdown yet", .{}),
                .pool => std.debug.panic("Worker.getThreadId() while worker is spawning",  .{}),
                .id => |thread_id| thread_id,
            };
        }
    };

    pub const Pool = extern struct {
        next: *Pool,
        scheduler: *Scheduler,
        workers_ptr: [*]Worker,
        workers_len: usize,
        runq: ?*Task align(CACHE_ALIGN),
        idle_queue: usize align(CACHE_ALIGN),
        active_threads: usize,

        const IDLE_MARKED = 1;
        const IDLE_SHUTDOWN = std.math.maxInt(usize);
        const MAX_WORKERS = (std.math.maxInt(usize) >> 8) - 1;

        pub fn init(noalias self: *Pool, workers: []Worker) void {
            const num_workers = std.math.min(workers.len, MAX_WORKERS);

            self.* = Pool{
                .next = self,
                .scheduler = undefined,
                .workers_ptr = workers.ptr,
                .workers_len = num_workers,
                .runq = null,
                .idle_queue = num_workers << 8,
                .active_threads = 0,
            };

            for (workers[0..num_workers]) |*worker, index| {
                const next_worker = self.fromWorkerIndex(index);
                const worker_ref = Worker.Ref{ .worker = @ptrToInt(next_worker) };
                worker.* = Worker{ .ptr = worker_ref.toUsize() };
            }
        }

        pub fn deinit(self: *Pool) void {
            defer self.* = undefined;

            const idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
            if (idle_queue != IDLE_SHUTDOWN)
                std.debg.panic("Pool.deinit() when not shutdown", .{});

            const runq = @atomicLoad(?*Task, &self.runq, .Monotonic);
            if (runq != null)
                std.debug.panic("Pool.deinit() when runq not empty", .{});

            const active_threads = @atomicLoad(usize, &self.active_threads, .Monotonic);
            if (active_threads != 0)
                std.debug.panic("Pool.deinit() with {} active threads", .{active_threads});
        }

        pub fn getWorkers(self: Pool) []Worker {
            return self.workers_ptr[0..self.workers_len];
        }

        fn fromWorkerIndex(self: *Pool, index: usize) ?*Worker {
            if (index == 0)
                return null;
            return &self.getWorkers()[index - 1];
        }

        fn toWorkerIndex(self: Pool, worker: ?*Worker) usize {
            const ptr = @ptrToInt(worker orelse return 0);
            const workers = self.getWorkers();

            const base = @ptrToInt(workers.ptr);
            const end = base + (@sizeOf(Worker) * workers.len);

            if ((ptr < base) or (ptr >= end))
                return 0;
            return (ptr - base) / @sizeOf(Worker);
        }

        pub fn push(self: *Pool, tasks: Batch) void {
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

        pub const Scheduled = struct {
            ptr: usize,
            pool: usize,
            
            pub const Action = union(enum) {
                spawned: *Worker,
                resumed: *Thread,
            };

            fn init(
                action: Action,
                pool: *Pool,
                first_in_pool: bool,
                first_in_scheduler: bool,
            ) Scheduled {
                return Scheduled{
                    .ptr = switch (action) {
                        .spawned => |worker| @ptrToInt(worker) | 0,
                        .resumed => |thread| @ptrToInt(thread) | 1,
                    },
                    .pool => @ptrToInt(pool)
                        | @boolToInt(first_in_pool)
                        | (@boolToInt(first_in_scheduler) << 1),
                };
            }

            pub fn getAction(self: Scheduled) Action {
                const ptr = self.ptr & ~@as(usize, 1);
                return switch (self.ptr & 1) {
                    0 => Action{ .spawned = @intToPtr(*Worker, ptr) },
                    1 => Action{ .resumed = @intToPtr(*Thread, ptr) },
                };
            } 

            pub fn getPool(self: Scheduled) *Pool {
                return @intToPtr(*Pool, self.pool & ~@as(usize, 0b11));
            }

            pub fn wasFirstInPool(self: Scheduled) bool {
                return self.pool & 0b01 != 0;
            }

            pub fn wasFirstInScheduler(self; Scheduled) bool {
                return self.pool & 0b10 != 0;
            }
        };

        pub fn tryResume(self: *Pool, from_any_pool: bool) ?Scheduled {
            return self.tryResumeThread(.{
                .was_waking = false,
                .check_all = from_any_pool, 
            }) catch null;
        }

        const ResumeOptions = struct {
            was_waking: bool,
            check_all: bool,
        };

        fn tryResumeThread(self: *Pool, options: ResumeOptions) error{Empty}!?Scheduled {
            var idle_queue = @atomicLoad(usize, &self.idle_queue, .Acquire);

            while (true) {
                if (idle_queue == IDLE_SHUTDOWN)
                    std.debug.panic("Pool.tryResumeThread() when already shutdown", .{});

                if (!options.was_waking and (idle_queue & IDLE_MARKED != 0))
                    break;

                const worker_index = idle_queue >> 8;
                var new_action: ?Scheduled.Action = null;
                var new_idle_queue = (idle_queue & ~@as(usize, ~@as(u8, 0))) | IDLE_MARKED;

                if (worker_index != 0) {
                    const worker = &self.getWorkers()[worker_index - 1];
                    const worker_ptr = @atomicLoad(usize, &worker.ptr, .Acquire);
                    switch (Worker.Ref.fromUsize(worker_ptr)) {
                        .worker => |ptr| {
                            switch ((ptr >> 2) & 1) {
                                0 => {
                                    const next_worker = @intToPtr(?*Worker, ptr & ~@as(usize, 0b111));
                                    new_action = Scheduled.Action{ .spawned = worker };
                                    new_idle_queue |= self.toWorkerIndex(next_worker) << 8;
                                },
                                1 => {
                                    const thread = @intToPtr(*Thread, ptr & ~@as(usize, 0b111));
                                    const next_worker = @atomicLoad(?*Worker, &thread.worker, .Unordered);
                                    new_action = Scheduled.Action{ .resumed = thread };
                                    new_idle_queue |= self.toWorkerIndex(next_worker) << 8;
                                },
                                else => unreachable,
                            }
                        },
                        .thread, .pool => {
                            idle_queue = @atomicLoad(usize, &self.idle_queue, .Acquire);
                            continue;
                        },
                        .id => {
                            std.debug.panic("Pool.tryResumeThread() when worker {} already shutting down", .{worker_index - 1});
                        },
                    }
                }

                if (@cmpxchgWeak(
                    usize,
                    &self.idle_queue,
                    idle_queue,
                    new_idle_queue,
                    .AcqRel,
                    .Acquire,
                )) |updated_idle_queue| {
                    idle_queue = updated_idle_queue;
                    continue;
                }

                const action = new_action orelse return null;
                const first_in_pool = @atomicRmw(usize, &self.active_threads, .Add, 1, .Monotonic) == 0;
                const first_in_scheduler = first_in_pool and {
                    break :blk @atomicRmw(usize, &self.scheduler.active_pools, .Add, 1, .Monotonic) == 0;
                };

                switch (action) {
                    .spawned => |worker| {
                        const worker_ref = Worker.Ref{ .pool = self };
                        @atomicStore(usize, &worker.ptr, worker_ref.toUsize(), .Release);
                    },
                    .resumed => |thread| {
                        const thread_ptr = @atomicLoad(usize, &thread.ptr, .Unordered);
                        const worker = @intToPtr(*Worker, thread_ptr);
                        @atomicStore(usize, &thread.ptr, @ptrToInt(pool) | 1, .Unordered);
                        @atomicStore(?*Worker, &thread.worker, worker, .Unordered);

                        const worker_ref = Worker.Ref{ .thread = thread };
                        @atomicStore(usize, &worker.ptr, worker_ref.toUsize(), .Release);
                    },
                }

                return Scheduled.init(
                    action,
                    self,
                    first_in_pool,
                    first_in_scheduler,
                );
            }

            if (options.check_all) {
                var cluster = self.iter();
                _ = cluster.next();
                while (cluster.next()) |remote_pool| {
                    return remote_pool.tryResume(.{
                        .was_waking = false,
                        .check_all = false,
                    }) catch continue;
                }
            }

            return error.Empty;
        }

        pub const Suspended = struct {
            value: usize,

            fn init(
                last_in_pool: bool,
                last_in_scheduler: bool,
            ) Suspended {
                return Suspended{
                    .value = @boolToInt(last_in_pool)
                        | (@boolToInt(last_in_scheduler) << 1),
                };
            }

            pub fn wasLastInPool(self: Suspended) bool {
                return (self.value & 0b01) != 0;
            }

            pub fn wasLastInScheduler(self: Suspended) bool {
                return (self.value & 0b10) != 0;
            }
        };

        pub fn trySuspend(self: *Pool, noalias thread: *Thread) ?Suspended {
            const worker = @atomicLoad(?*Worker, &thread.worker, .Unordered);
            const thread_ptr = @atomicLoad(usize, &thread.ptr, .Unordered);

            const was_waking = (thread_ptr & 1) != 0;
            const pool = @intToPtr(?*Pool, thread_ptr & ~@as(usize, 1));
            if (pool != self)
                std.debug.panic("Pool.trySuspend() with non owned thread", .{});

            var idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
            while (true) {
                if (idle_queue == IDLE_SHUTDOWN)
                    std.debug.panic("Pool.trySuspend() when pool is shutting down", .{});

                var worker_index = idle_queue >> 8;
                var aba_tag = @truncate(u7, idle_queue >> 1);
                var is_marked = (idle_queue & IDLE_MARKED) != 0;

                var was_notified = false;
                if (worker_index == 0 and !is_marked) {
                    is_marked = true;
                    was_notified = true;

                } else {
                    const next_worker = self.fromWorkerIndex(worker_index);
                    const worker_ref = WorkerRef{ .worker = @ptrToInt(thread) | 0b100 };
                    @atomicStore(?*Worker, &thread.worker, next_worker, .Unordered);
                    @atomicStore(usize, &thread.ptr, @ptrToInt(worker), .Unordered);
                    @atomicStore(usize, &worker.ptr, worker_ref.toUsize(), .Release);

                    if (was_waking)
                        is_marked = false;
                    aba_tag +%= 1;
                    worker_index = self.toWorkerIndex(worker);
                }        

                const new_idle_queue = (worker_index << 8)
                    | (@as(usize, aba_tag) << 1)
                    | @boolToInt(is_marked);

                if (@cmpxchgWeak(
                    usize,
                    &self.idle_queue,
                    idle_queue,
                    new_idle_queue,
                    .AcqRel,
                    .Monotonic,
                )) |updated_idle_queue| {
                    idle_queue = updated_idle_queue;
                    continue;
                }

                if (was_notified) {
                    const worker_ref = Worker.Ref{ .thread = thread };
                    @atomicStore(?*Worker, &thread.worker, worker, .Unordered);
                    @atomicStore(usize, &thread.ptr, @ptrToInt(pool) | @boolToInt(was_waking), .Unordered);
                    @atomicStore(usize, &worker.ptr, worker_ref.toUsize(), .Release);
                    return null;
                }

                const last_in_pool = @atomicRmw(usize, &self.active_threads, .Sub, 1, .Monotonic) == 1;
                const last_in_scheduler = last_in_pool and blk: {
                    break :blk @atomicRmw(usize, &self.scheduler.active_pools, .Sub, 1, .Monotonic) == 1;
                };

                return Suspended.init(
                    last_in_pool,
                    last_in_scheduler,
                );
            }
        }

        pub fn shutdown(self: *Pool) SuspendedThreadIter {
            @atomicStore(usize, &self.idle_queue, IDLE_SHUTDOWN, .Monotonic);
            @fence(.SeqCst);

            var idle_threads: ?*Thread = null;
            for (self.getWorkers()) |*worker, index| {
                const worker_ptr = @atomicLoad(usize, &worker.ptr, .Acquire);
                switch (Worker.Ref.fromUsize(worker_ptr)) {
                    .thread => std.debug.panic("Pool.shutdown() when thread on worker {} was still running", .{index}),
                    .pool => std.debug.panic("Pool.shutdown() when worker {} was spawning", .{index}),
                    .id => std.debug.panic("Pool.shutdown() when worker {} was already shutdown", .{index}),
                    .worker => |ptr| {
                        const thread_id = switch ((ptr >> 2) & 1) {
                            0 => null,
                            1 => blk: {
                                const thread = @intToPtr(*Thread, ptr & ~@as(usize, 0b111));
                                thread.ptr = @ptrToInt(idle_threads);
                                idle_threads = thread;
                                break :blk thread.id;
                            },
                            else => unreachable,
                        };
                        const worker_ref = Worker.Ref{ .id = thread_id };
                        @atomicStore(usize, &worker.ptr, worker_ref.toUsize(), .Release);
                    },
                }
            }

            return SuspendedThreadIter{
                .idle_threads = idle_threads,
            };
        }

        pub const SuspendedThreadIter = extern struct {
            idle_threads: ?*Thread,

            pub fn next(self: *SuspendedThreadIter) ?*Thread {
                const thread = self.idle_threads orelse return null;
                const thread_ptr = @atomicLoad(usize, &thread.ptr, .Unordered);
                self.idle_threads = @intToPtr(?*Thread, thread_ptr);
                return thread;
            }
        };

        pub fn join(self: *Pool) ShutdownThreadIter {
            return ShutdownThreadIter{
                .pool = self,
                .index = 0,
            };
        }

        pub const ShutdownThreadIter = extern struct {
            pool: *Pool,
            index: usize,

            pub fn next(self: *ShutdownThreadIter) Thread.Id {
                const workers = pool.getWorkers();
                while (self.index < workers.len) {
                    const worker_index = self.index;
                    const worker_ptr = @atomicLoad(usize, &workers[worker_index], .Acquire);
                    self.index += 1;

                    switch (Worker.Ref.fromUsize(worker_ptr)) {
                        .id => |thread_id| {
                            if (thread_id) |tid|
                                return tid;
                        }
                        .worker, .thread, .pool => {
                            std.debug.panic("ShutdownThreadIter.next() when worker {} not shutdown", .{worker_index});
                        },
                    }
                }
            }
        };

        pub fn iter(self: *Pool) Cluster.Iter {
            return Cluster.Iter.init(self);
        }

        pub const Cluster = extern struct {
            head: ?*Pool = null,
            tail: *Pool = undefined,

            pub fn from(pool: *Pool) Cluster {
                pool.next = pool;
                return Cluster{
                    .head = pool,
                    .tail = pool,
                };
            }

            pub fn push(noalias self: *Cluster, noalias pool: *Pool) void {
                return self.pushFront(pool);
            }

            pub fn pushFront(noalias self: *Cluster, noalias pool: *Pool) void {
                return self.pushFrontMany(Cluster.from(pool));
            }

            pub fn pushBack(noalias self: *Cluster, noalias pool: *Pool) void {
                return self.pushBackMany(Cluster.from(pool));
            }

            pub fn pushFrontMany(noalias self: *Cluster, cluster: Cluster) void {
                if (cluster.head) |cluster_head| {
                    if (self.head) |head| {
                        cluster.tail.next = head;
                        self.tail.next = cluster_head;
                        self.head = cluster_head;
                    } else {
                        self.* = cluster;
                    }
                }
            }

            pub fn pushBackMany(noalias self: *Cluster, cluster: Cluster) void {
                if (cluster.head) |cluster_head| {
                    if (self.head) |head| {
                        self.tail.next = cluster_head;
                        cluster.tail.next = head;
                        self.tail = cluster.tail;
                    } else {
                        self.* = cluster;
                    }
                }
            }

            pub fn pop(noalias self: *Cluster) ?*Pool {
                return self.popFront();
            }

            pub fn popFront(noalias self: *Cluster) ?*Pool {
                const pool = self.head orelse return null;
                self.head = pool.next;
                if (self.head == pool)
                    self.head = null;
                pool.next = pool;
                return pool;
            }

            pub fn iter(self: Cluster) Iter {
                return Iter.init(self.head);
            }

            pub const Iter = extern struct {
                start: *Pool,
                current: ?*Pool,

                fn init(pool: ?*Pool) Iter {
                    return Iter{
                        .start = pool orelse undefined,
                        .current = pool,
                    };
                }

                pub fn next(self: *Iter) ?*Pool {
                    const pool = self.current orelse return null;
                    self.current = pool.next;
                    if (self.current == self.start)
                        self.current = null;
                    return pool;
                }
            };
        };
    };

    pub const Scheduler = extern struct {
        starting_pool: ?*Pool,
        active_pools: usize,

        pub fn init(noalias self: *Scheduler, cluster: Pool.Cluster) void {
            self.* = Scheduler{
                .starting_pool = cluster.head,
                .active_pools = 0,
            };
        }

        pub fn deinit(self: *Scheduler) void {
            defer self.* = undefined;

            const active_pools = @atomicLoad(usize, &self.active_pools, .Monotonic);
            if (active_pools != 0)
                std.debug.panic("Scheduler.deinit() with {} active pools", .{active_pools});
        }

        pub fn getPoolIter(self: Scheduler) Pool.Cluster.Iter {
            return Pool.Cluster.Iter.init(self.starting_pool);
        }
    };
};

