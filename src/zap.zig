// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const assert = std.debug.assert;

pub const Task = extern struct {
    next: ?*Task = undefined,
    frame: usize,

    pub fn init(frame: anyframe) Task {
        return Task{ .frame = @ptrToInt(frame) };
    }

    pub fn execute(self: *Task, worker: *Worker) void {
        resume blk: {
            @setRuntimeSafety(false);
            break :blk @intToPtr(anyframe, self.frame);
        };
    }

    pub const RunConfig = struct {
        threads: usize = 0,
    };

    fn ReturnTypeOf(comptime asyncFn: anytype) type {
        return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
    }

    pub fn run(
        config: RunConfig,
        comptime asyncFn: anytype,
        args: anytype,
    ) !ReturnTypeOf(asyncFn) {
        return runWithShutdown(config, asyncFn, args, true);
    }

    pub fn runForever(
        config: RunConfig,
        comptime asyncFn: anytype,
        args: anytype,
    ) !ReturnTypeOf(asyncFn) {
        return runWithShutdown(config, asyncFn, args, false);
    }

    fn runWithShutdown(
        config: RunConfig,
        comptime asyncFn: anytype,
        args: anytype,
        comptime shutdown_after_async_fn: bool,
    ) !ReturnTypeOf(asyncFn) {
        const Args = @TypeOf(args);
        const ReturnType = ReturnTypeOf(asyncFn);

        const Wrapper = struct {
            fn entry(fn_args: Args, task: *Task, result: *?ReturnType) void {
                suspend task.* = Task.init(@frame());
                const result_value = @call(.{}, asyncFn, fn_args);
                suspend {
                    result.* = result_value;
                    if (shutdown_after_async_fn)
                        Task.shutdown();
                }
            }
        };

        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.entry(args, &task, &result);

        const num_threads = blk: {
            if (std.builtin.single_threaded) {
                break :blk @as(usize, 1);
            } else if (config.threads > 0) {
                break :blk config.threads;
            } else {
                break :blk (std.Thread.cpuCount() catch 1);
            }
        };

        var scheduler: Scheduler = undefined;
        scheduler.init(num_threads);
        scheduler.push(Batch.from(&task));
        scheduler.resumeWorker(.{ .use_caller_thread = true });

        return result orelse error.DeadLocked;
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
            return self.pushMany(Batch.from(task));
        }

        pub fn pushMany(self: *Batch, other: Batch) void {
            if (other.isEmpty())
                return;    
            if (self.isEmpty()) {
                self.* = other;
            } else {
                self.tail.next = other.head;
                self.tail = other.tail;
            }
        }

        pub fn pop(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }

        pub fn schedule(self: Batch) void {
            const worker = Worker.current orelse {
                std.debug.panic("Cannot schedule tasks from outside the thread pool", .{});
            };
            worker.schedule(self);
        }
    };

    pub fn schedule(self: *Task) void {
        const batch = Batch.from(self);
        batch.schedule();
    }

    pub fn scheduleNext(self: *Task) void {
        const worker = Worker.current orelse {
            std.debug.panic("Cannot yield into a task from outside the thread pool", .{});
        };

        if (worker.run_next) |old_next| {
            worker.schedule(Batch.from(old_next));
        }

        worker.run_next = self;
    }

    pub fn runConcurrently() void {
        suspend {
            var task = Task.init(@frame());
            task.schedule();
        }
    }

    pub fn yield() void {
        const worker = Worker.current orelse {
            std.debug.panic("Cannot yield from outside the thread pool", .{});
        };

        worker.run_next = worker.pollTask() orelse return;
        suspend {
            var task = Task.init(@frame());
            worker.run_queue.push(Batch.from(&task));
        }
    }

    pub fn shutdown() void {
        const worker = Worker.current orelse {
            std.debug.panic("Cannot shutdown scheduler outside the thread pool", .{});
        };
        worker.scheduler.shutdown(worker);
    }

    pub const Lock = struct {
        state: usize = UNLOCKED,

        const UNLOCKED = 0;
        const LOCKED = 1;
        const WAKING = 1 << 8;
        const WAITING = ~@as(usize, (1 << 9) - 1);

        const Waiter = struct {
            prev: ?*Waiter align(~WAITING + 1),
            next: ?*Waiter,
            tail: ?*Waiter,
            event: std.AutoResetEvent,
        };

        fn tryAcquire(self: *Lock) bool {
            return @atomicRmw(
                u8,
                @ptrCast(*u8, &self.state),
                .Xchg,
                LOCKED,
                .Acquire,
            ) == UNLOCKED;
        }

        pub fn acquire(self: *Lock) void {
            if (std.builtin.single_threaded) {
                if (self.state == LOCKED)
                    unreachable; // dead-locked
                self.state = LOCKED;
                return;
            }

            if (!self.tryAcquire()) {
                self.acquireSlow();
            }
        }

        fn acquireSlow(self: *Lock) void {
            @setCold(true);

            var waiter: Waiter = undefined;
            waiter.event = std.AutoResetEvent{};

            var spin: std.math.Log2Int(usize) = 0;
            var state = @atomicLoad(usize, &self.state, .Monotonic);

            while (true) {
                if (state & LOCKED == 0) {
                    if (self.tryAcquire())
                        return;
                    std.os.sched_yield() catch unreachable;
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                    continue;
                }

                const head = @intToPtr(?*Waiter, state & WAITING);
                if (head == null and spin < 10) {
                    spin += 1;
                    if (spin <= 3) {
                        std.SpinLock.loopHint(@as(usize, 1) << spin);
                    } else {
                        std.os.sched_yield() catch unreachable;
                    }
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                    continue;
                }

                waiter.prev = null;
                waiter.next = head;
                waiter.tail = if (head == null) &waiter else null;

                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    (state & ~WAITING) | @ptrToInt(&waiter),
                    .Release,
                    .Monotonic,
                ) orelse blk: {
                    waiter.event.wait();
                    spin = 0;
                    state = @atomicRmw(usize, &self.state, .Sub, WAKING, .Monotonic);
                    break :blk (state - WAKING);
                };
            }
        }

        pub fn release(self: *Lock) void {
            if (std.builtin.single_threaded) {
                if (self.state != LOCKED)
                    unreachable; // dead-locked
                self.state = UNLOCKED;
                return;
            }

            @atomicStore(
                u8,
                @ptrCast(*u8, &self.state),
                UNLOCKED,
                .Release,
            );

            const state = @atomicLoad(usize, &self.state, .Monotonic);
            if ((state & WAITING != 0) and (state & (LOCKED | WAKING) == 0)) {
                self.releaseSlow();
            }
        }

        fn releaseSlow(self: *Lock) void {
            @setCold(true);

            var state = @atomicLoad(usize, &self.state, .Monotonic);
            while (true) {
                if ((state & WAITING == 0) or (state & (LOCKED | WAKING) != 0))
                    return;
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    state | WAKING,
                    .Acquire,
                    .Monotonic,
                ) orelse break;
            }

            state |= WAKING;
            dequeue: while (true) {
                const head = @intToPtr(*Waiter, state & WAITING);
                const tail = head.tail orelse blk: {
                    var current = head;
                    while (true) {
                        const next = current.next.?;
                        next.prev = current;
                        current = next;
                        if (current.tail) |tail| {
                            head.tail = tail;
                            break :blk tail;
                        }
                    }
                };

                if (state & LOCKED != 0) {
                    state = @cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        state & ~@as(usize, WAKING),
                        .Release,
                        .Acquire,
                    ) orelse return;
                    continue;
                }

                if (tail.prev) |new_tail| {
                    head.tail = new_tail;
                    @fence(.Release);
                } else {
                    while (true) {
                        state = @cmpxchgWeak(
                            usize,
                            &self.state,
                            state,
                            (state & LOCKED) | WAKING,
                            .Monotonic,
                            .Monotonic,
                        ) orelse break;
                        if (state & WAITING != 0) {
                            @fence(.Acquire);
                            continue :dequeue;
                        }
                    }
                }

                tail.event.set();
                return;
            }
        }
    };

    const IS_IDLE     = 0b0001;
    const IS_WAKING   = 0b0010;
    const IS_NOTIFIED = 0b0100;
    const IS_SHUTDOWN = 0b1000;
    const WORKER_MASK = ~@as(usize, IS_IDLE | IS_WAKING | IS_NOTIFIED | IS_SHUTDOWN);

    pub const Scheduler = struct {
        run_queue: ?*Task = null,
        idle_queue: IdleQueue = IdleQueue{ .value = 0 },
        max_workers: usize = 0,
        running: usize = 0,
        active_head: ?*Worker = null,
        shutdown_queue: ?*Worker = null,
        shutdown_event: std.AutoResetEvent = std.AutoResetEvent{},

        fn init(self: *Scheduler, workers: usize) void {
            const max_workers = std.math.min(workers, ~@as(usize, 0) >> 4);

            self.* = Scheduler{};
            self.max_workers = max_workers;
            self.idle_queue = IdleQueue{ .value = max_workers << 4 };

            // [ptr/remaining:61] [is_idle_ptr:1] [is_waking:1] [is_notified:1] [is_shutdown:1]
        }

        pub fn schedule(self: *Scheduler, batch: Batch) void {
            if (batch.isEmpty())
                return;

            self.push(batch);
            self.resumeWorker(.{});
        }

        fn push(self: *Scheduler, batch: Batch) void {
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
                ) orelse return;
            }
        }

        fn popAll(self: *Scheduler) ?*Task {
            var run_queue = @atomicLoad(?*Task, &self.run_queue, .Monotonic);
            while (true) {
                const head_task = run_queue orelse return null;
                run_queue = @cmpxchgWeak(
                    ?*Task,
                    &self.run_queue,
                    run_queue,
                    null,
                    .Acquire,
                    .Monotonic,
                ) orelse return head_task;
            }
        }

        const ResumeContext = struct {
            is_waking: bool = false,
            use_caller_thread: bool = false,
        };

        const ResumeType = union(enum) {
            notified: void,
            resumed: *Worker,
            spawned: void,
        };

        fn resumeWorker(self: *Scheduler, context: ResumeContext) void {
            var inc_running = false;
            var resume_type: ResumeType = undefined;
            var idle_queue = self.idle_queue.load(.Acquire);

            while (true) {
                const queue = idle_queue.value;
                var new_queue: usize = queue;

                if (queue & IS_SHUTDOWN != 0)
                    return;

                if (context.is_waking) {
                    assert(queue & IS_WAKING != 0);
                    new_queue &= ~@as(usize, IS_NOTIFIED);
                }

                if (!context.is_waking and (queue & IS_WAKING != 0)) {
                    if (queue & IS_NOTIFIED != 0)
                        return;
                    resume_type = .notified;
                    new_queue |= IS_NOTIFIED;
                    
                } else if (queue & IS_IDLE != 0) {
                    const worker = @intToPtr(*Worker, queue & WORKER_MASK);
                    resume_type = .{ .resumed = worker };
                    new_queue |= IS_WAKING;

                    const worker_next = @atomicLoad(usize, &worker.next, .Unordered);
                    new_queue = (new_queue & ~WORKER_MASK) | (worker_next & WORKER_MASK);
                    if (worker_next & IS_IDLE == 0)
                        new_queue &= ~@as(usize, IS_IDLE);

                } else if (queue & WORKER_MASK != 0) {
                    const workers_shift = @popCount(std.math.Log2Int(usize), ~WORKER_MASK);
                    const free_workers = queue >> workers_shift;
                    resume_type = .spawned;
                    new_queue = (new_queue & ~WORKER_MASK) | ((free_workers - 1) << workers_shift) | IS_WAKING;

                } else if (context.is_waking) {
                    resume_type = .notified;
                    new_queue &= ~@as(usize, IS_WAKING);

                } else {
                    const running = @atomicLoad(usize, &self.running, .Monotonic);
                    assert(running <= self.max_workers);
                    if (running == self.max_workers)
                        return;

                    resume_type = .spawned;
                    if (@cmpxchgWeak(
                        usize,
                        &self.running,
                        running,
                        running + 1,
                        .Monotonic,
                        .Monotonic,
                    )) |_failed| {
                        idle_queue = self.idle_queue.load(.Acquire);
                        continue;
                    } else {
                        inc_running = true;
                    }
                }

                idle_queue = self.idle_queue.cmpxchgWeak(
                    idle_queue,
                    new_queue,
                    .Acquire,
                    .Acquire,
                ) orelse break;

                if (inc_running) {
                    inc_running = false;
                    _ = @atomicRmw(usize, &self.running, .Sub, 1, .Monotonic);
                }
            }

            switch (resume_type) {
                .notified => {
                    return;
                },
                .spawned => {
                    if (!inc_running) {
                        _ = @atomicRmw(usize, &self.running, .Add, 1, .Monotonic);
                    }
                },
                .resumed => |worker| {
                    assert(!std.builtin.single_threaded);
                    assert(worker.state == .suspended);
                    worker.state = .waking;
                    worker.event.set();
                    return;
                },
            }

            var spawn_info = @ptrToInt(self) | @enumToInt(Worker.SpawnInfo.scheduler);
            if (context.use_caller_thread) {
                Worker.run(&spawn_info);
                return;
            }

            if (std.builtin.single_threaded)
                unreachable; // tried to spawn a worker thread when single-threaded

            spawn_info = @ptrToInt(self) | @enumToInt(Worker.SpawnInfo.spawning);
            if (std.Thread.spawn(&spawn_info, Worker.run)) |thread| {
                var spawned = Worker.SpawnInfo.Spawned{
                    .thread = thread,
                    .scheduler = self,
                    .event = std.AutoResetEvent{},
                };

                const info = @cmpxchgStrong(
                    usize,
                    &spawn_info,
                    @ptrToInt(self) | @enumToInt(Worker.SpawnInfo.spawning),
                    @ptrToInt(&spawned) | @enumToInt(Worker.SpawnInfo.spawned),
                    .Release,
                    .Acquire,
                ) orelse {
                    spawned.event.wait();
                    return;
                };

                const info_type = @intToEnum(Worker.SpawnInfo, @truncate(@TagType(Worker.SpawnInfo), info));
                assert(info_type == .waiting);
                const worker = @intToPtr(*Worker, info & ~@as(usize, ~@as(@TagType(Worker.SpawnInfo), 0)));
                worker.thread = thread;
                worker.event.set();

            } else |err| {
                _ = @atomicRmw(usize, &self.running, .Sub, 1, .Monotonic);
            }
        }

        fn suspendWorker(noalias self: *Scheduler, noalias worker: *Worker) void {
            const worker_state = worker.state;
            var new_worker_state: Worker.State = undefined;
            var idle_queue = self.idle_queue.load(.Monotonic);

            while (true) {
                const queue = idle_queue.value;
                var new_queue: usize = undefined;

                if (queue & IS_SHUTDOWN != 0) {
                    new_worker_state = .shutdown;
                    worker.state = new_worker_state;
                    break;

                } else if (worker_state == .waking and (queue & IS_NOTIFIED != 0)) {
                    new_worker_state = worker_state;
                    worker.state = new_worker_state;
                    assert(queue & IS_WAKING != 0);
                    new_queue = queue & ~@as(usize, IS_WAKING | IS_NOTIFIED);

                } else {
                    @atomicStore(usize, &worker.next, queue, .Unordered);
                    new_worker_state = .suspended;
                    worker.state = new_worker_state;
                    new_queue = (queue & ~WORKER_MASK);
                    new_queue |= @ptrToInt(worker) | IS_IDLE;
                    if (worker_state == .waking)
                        new_queue &= ~@as(usize, IS_WAKING);
                }

                idle_queue = self.idle_queue.cmpxchgWeak(
                    idle_queue,
                    new_queue,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }

            if (new_worker_state == .suspended) {
                worker.event.wait();
            }
        }

        pub fn shutdown(noalias self: *Scheduler, noalias _worker: *Worker) void {
            var idle_queue = self.idle_queue.load(.Monotonic);
            while (true) {
                if (idle_queue.value & IS_SHUTDOWN != 0)
                    return;
                idle_queue = self.idle_queue.cmpxchgWeak(
                    idle_queue,
                    IS_SHUTDOWN,
                    .Acquire,
                    .Monotonic,
                ) orelse break;
            }

            var queue = idle_queue.value;
            while (queue & IS_IDLE != 0) {
                const idle_worker = @intToPtr(*Worker, queue & WORKER_MASK);
                queue = @atomicLoad(usize, &idle_worker.next, .Unordered);
                idle_worker.state = .shutdown;
                idle_worker.event.set();
            }
        }

        fn onWorkerBegin(noalias self: *Scheduler, noalias worker: *Worker) void {
            var active_head = @atomicLoad(?*Worker, &self.active_head, .Monotonic);
            while (true) {
                worker.active_next = active_head;
                active_head = @cmpxchgWeak(
                    ?*Worker,
                    &self.active_head,
                    active_head,
                    worker,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }
        }

        fn onWorkerEnd(noalias self: *Scheduler, noalias worker: *Worker) void {
            var shutdown_queue = @atomicLoad(?*Worker, &self.shutdown_queue, .Monotonic);
            while (true) {
                @atomicStore(usize, &worker.next, @ptrToInt(shutdown_queue) | IS_IDLE, .Unordered);
                shutdown_queue = @cmpxchgWeak(
                    ?*Worker,
                    &self.shutdown_queue,
                    shutdown_queue,
                    worker,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }

            const running = @atomicRmw(usize, &self.running, .Sub, 1, .Monotonic);
            if (running == 1)
                self.shutdown_event.set();

            if (worker.thread != null) {
                worker.event.wait();
                return;
            }

            self.shutdown_event.wait();

            var shutdown_workers = @atomicLoad(?*Worker, &self.shutdown_queue, .Acquire);
            shutdown_workers = shutdown_workers orelse {
                unreachable; // shutdown thread found no workers on the shutdown queue
            };

            while (shutdown_workers) |idle_worker| {
                const shutdown_worker = idle_worker;
                const worker_next = @atomicLoad(usize, &idle_worker.next, .Unordered);
                assert(worker_next & IS_IDLE != 0);
                shutdown_workers = @intToPtr(?*Worker, worker_next & WORKER_MASK);

                const shutdown_thread = shutdown_worker.thread;
                shutdown_worker.event.set();
                if (shutdown_thread) |thread|
                    thread.wait();
            }
        }

        const IdleQueue = switch (std.builtin.arch) {
            .i386, .x86_64 => extern struct {
                const DoubleUsize = std.meta.Int(.unsigned, std.meta.bitCount(usize) * 2);

                value: usize align(@alignOf(DoubleUsize)),
                aba_tag: usize = 0,

                fn load(
                    self: *const IdleQueue,
                    comptime ordering: std.builtin.AtomicOrder,
                ) IdleQueue {
                    const value = @atomicLoad(usize, &self.value, ordering);
                    const aba_tag = @atomicLoad(usize, &self.value, .Monotonic);
                    return IdleQueue{
                        .value = value,
                        .aba_tag = aba_tag,
                    };
                }

                fn cmpxchgWeak(
                    self: *IdleQueue,
                    cmp: IdleQueue,
                    xchg: usize,
                    comptime success: std.builtin.AtomicOrder,
                    comptime failure: std.builtin.AtomicOrder,
                ) ?IdleQueue {
                    const double_usize = @cmpxchgWeak(
                        DoubleUsize,
                        @ptrCast(*DoubleUsize, self),
                        @bitCast(DoubleUsize, cmp),
                        @bitCast(DoubleUsize, IdleQueue{
                            .value = xchg,
                            .aba_tag = cmp.aba_tag +% 1,
                        }),
                        success,
                        failure,
                    ) orelse return null;
                    return @bitCast(IdleQueue, double_usize);
                }
            },
            else => extern struct {
                value: usize,

                fn load(
                    self: *const IdleQueue,
                    comptime ordering: std.builtin.AtomicOrder,
                ) IdleQueue {
                    const value = @atomicLoad(usize, &self.value, ordering);
                    return IdleQueue{ .value = value };
                }

                fn cmpxchgWeak(
                    self: *IdleQueue,
                    cmp: IdleQueue,
                    xchg: usize,
                    comptime success: std.builtin.AtomicOrder,
                    comptime failure: std.builtin.AtomicOrder,
                ) ?IdleQueue {
                    const value = @cmpxchgWeak(
                        usize,
                        &self.state,
                        cmp.value,
                        xchg,
                        success,
                        failure,
                    ) orelse return null;
                    return IdleQueue{ .value = value };
                }
            },
        };
    };

    pub const Worker = struct {
        state: State align(16),
        target: ?*Worker,
        next: usize,
        active_next: ?*Worker,
        thread: ?*std.Thread,
        scheduler: *Scheduler,
        event: std.AutoResetEvent,
        run_next: ?*Task,
        run_queue: RunQueue,

        const State = enum {
            waking,
            running,
            suspended,
            shutdown,
        };

        const SpawnInfo = enum(u2) {
            scheduler, // ptr = *Scheduler
            spawning, // ptr = *Scheduler
            spawned, // ptr = *Spawned
            waiting, // ptr = *Worker

            const Spawned = struct {
                thread: *std.Thread,
                scheduler: *Scheduler,
                event: std.AutoResetEvent,
            };
        };

        threadlocal var current: ?*Worker = null;

        fn run(spawn_info: *usize) void {
            var self = Worker{
                .state = .waking,
                .target = null,
                .next = IS_IDLE,
                .active_next = null,
                .thread = null,
                .scheduler = undefined,
                .event = std.AutoResetEvent{},
                .run_next = null,
                .run_queue = RunQueue{},
            };

            var info = @ptrToInt(&self) | @enumToInt(SpawnInfo.waiting);
            info = @atomicRmw(usize, spawn_info, .Xchg, info, .AcqRel);

            const info_ptr = info & ~@as(usize, ~@as(@TagType(SpawnInfo), 0));
            switch (@intToEnum(SpawnInfo, @truncate(@TagType(SpawnInfo), info))) {
                .scheduler => {
                    self.scheduler = @intToPtr(*Scheduler, info_ptr);
                },
                .waiting => {
                    unreachable; // mutiple Workers waiting on the same spawn_info ptr
                },
                .spawning => {
                    self.scheduler = @intToPtr(*Scheduler, info_ptr);
                    self.event.wait();
                },
                .spawned => {
                    const spawned = @intToPtr(*SpawnInfo.Spawned, info_ptr);
                    self.thread = spawned.thread;
                    self.scheduler = spawned.scheduler;
                    spawned.event.set();
                },
            }

            const old_current = Worker.current;
            Worker.current = &self;
            defer Worker.current = old_current;

            self.scheduler.onWorkerBegin(&self);
            defer self.scheduler.onWorkerEnd(&self);

            while (true) {
                if (self.pollTask()) |task| {
                    task.execute(&self);
                    continue;
                }

                self.scheduler.suspendWorker(&self);

                switch (self.state) {
                    .shutdown => break,
                    .waking, .running => {},
                    .suspended => unreachable, // worker running when suspended
                }
            }
        }

        fn pollTask(self: *Worker) ?*Task {
            var injected = false;
            const task = self.findTask(&injected) orelse return null;

            const is_waking = self.state == .waking;
            if (is_waking or injected) {
                self.scheduler.resumeWorker(.{ .is_waking = is_waking });
                self.state = .running;
            }

            return task;
        }

        fn findTask(noalias self: *Worker, noalias injected: *bool) ?*Task {
            if (self.run_next) |next_task| {
                const task = next_task;
                self.run_next = null;
                return task;
            }

            if (self.run_queue.pop(injected)) |task| {
                return task;
            }

            const scheduler = self.scheduler;

            var attempts: usize = 2;
            while (attempts > 0) : (attempts -= 1) {

                var active = @atomicLoad(usize, &scheduler.running, .Monotonic);
                while (active != 0) : (active -= 1) {

                    const target = self.target orelse blk: {
                        const target = @atomicLoad(?*Worker, &scheduler.active_head, .Acquire);
                        self.target = target;
                        break :blk target orelse unreachable; // no active_head when trying to steal
                    };

                    self.target = target.active_next;
                    if (target == self)
                        continue;

                    if (self.run_queue.steal(&target.run_queue, injected)) |task| {
                        return task;
                    }
                }
            }

            if (scheduler.popAll()) |head_task| {
                self.run_queue.inject(head_task.next, injected);
                return head_task;
            }

            return null;
        }

        fn schedule(self: *Worker, batch: Batch) void {
            if (batch.isEmpty())
                return;

            self.run_queue.push(batch);
            self.scheduler.resumeWorker(.{});
        }

        const RunQueue = struct {
            head: usize = 0,
            tail: usize = 0,
            next: ?*Task = null,
            overflow: ?*Task = null,
            buffer: [256]*Task = undefined,

            fn push(self: *RunQueue, tasks: Batch) void {
                var batch = tasks;
                var tail = self.tail;
                var head = @atomicLoad(usize, &self.head, .Monotonic);
        
                while (true) {
                    if (batch.isEmpty())
                        return;

                    if (@atomicLoad(?*Task, &self.next, .Monotonic) == null) {
                        const task = batch.pop() orelse unreachable; // !batch.isEmpty() but failed pop
                        @atomicStore(?*Task, &self.next, task, .Release);
                        continue;
                    }

                    var size = tail -% head;
                    if (size < self.buffer.len) {
                        while (size < self.buffer.len) : (size += 1) {
                            const task = batch.pop() orelse break;
                            @atomicStore(*Task, &self.buffer[tail % self.buffer.len], task, .Unordered);
                            tail +%= 1;
                        }
                        @atomicStore(usize, &self.tail, tail, .Release);
                        head = @atomicLoad(usize, &self.head, .Monotonic);
                        continue;
                    }

                    const new_head = head +% (self.buffer.len / 2);
                    if (@cmpxchgWeak(
                        usize,
                        &self.head,
                        head,
                        new_head,
                        .Monotonic,
                        .Monotonic,
                    )) |updated_head| {
                        head = updated_head;
                        continue;
                    }

                    var overflowed = Batch{};
                    while (head != new_head) : (head +%= 1)
                        overflowed.push(self.buffer[head % self.buffer.len]);
                    overflowed.pushMany(batch);

                    var overflow = @atomicLoad(?*Task, &self.overflow, .Monotonic);
                    while (true) {
                        overflowed.tail.next = overflow;

                        if (overflow == null) {
                            @atomicStore(?*Task, &self.overflow, overflowed.head, .Release);
                            return;
                        }

                        overflow = @cmpxchgWeak(
                            ?*Task,
                            &self.overflow,
                            overflow,
                            overflowed.head,
                            .Release,
                            .Monotonic,
                        ) orelse return;
                    }
                }
            }

            fn pop(self: *RunQueue, injected: *bool) ?*Task {
                var next_task = @atomicLoad(?*Task, &self.next, .Monotonic);
                while (next_task) |task| {
                    next_task = @cmpxchgWeak(
                        ?*Task,
                        &self.next,
                        next_task,
                        null,
                        .Monotonic,
                        .Monotonic,
                    ) orelse return task;
                }

                var tail = self.tail;
                var head = @atomicLoad(usize, &self.head, .Monotonic);
                while (tail != head) {
                    head = @cmpxchgWeak(
                        usize,
                        &self.head,
                        head,
                        head +% 1,
                        .Monotonic,
                        .Monotonic,
                    ) orelse return self.buffer[head % self.buffer.len];
                }

                var overflow = @atomicLoad(?*Task, &self.overflow, .Monotonic);
                while (overflow) |head_task| {
                    overflow = @cmpxchgWeak(
                        ?*Task,
                        &self.overflow,
                        overflow,
                        null,
                        .Monotonic,
                        .Monotonic,
                    ) orelse {
                        self.inject(head_task.next, injected);
                        return head_task;
                    };
                }

                return null;
            }

            fn steal(
                noalias self: *RunQueue,
                noalias target: *RunQueue,
                noalias injected: *bool,
            ) ?*Task {
                var tail = self.tail;
                var head = @atomicLoad(usize, &self.head, .Monotonic);
                std.debug.assert(tail == head);

                var target_head = @atomicLoad(usize, &target.head, .Monotonic);
                while (true) {
                    const target_tail = @atomicLoad(usize, &target.tail, .Acquire);

                    const target_size = target_tail -% target_head;
                    if (target_size > target.buffer.len) {
                        std.SpinLock.loopHint(1);
                        target_head = @atomicLoad(usize, &target.head, .Monotonic);
                        continue;
                    }

                    var num_steal = target_size - (target_size / 2);
                    if (num_steal == 0) {
                        if (@atomicLoad(?*Task, &target.overflow, .Monotonic)) |head_task| {
                            _ = @cmpxchgWeak(
                                ?*Task,
                                &target.overflow,
                                head_task,
                                null,
                                .Acquire,
                                .Monotonic,
                            ) orelse {
                                self.inject(head_task.next, injected);
                                return head_task;
                            };
                        } else if (@atomicLoad(?*Task, &target.next, .Monotonic)) |next_task| {
                            _ = @cmpxchgWeak(
                                ?*Task,
                                &target.next,
                                next_task,
                                null,
                                .Acquire,
                                .Monotonic,
                            ) orelse return next_task;
                        } else {
                            return null;
                        }
                        
                        std.SpinLock.loopHint(1);
                        target_head = @atomicLoad(usize, &target.head, .Monotonic);
                        continue;
                    }
                    
                    const first_task = @atomicLoad(*Task, &target.buffer[target_head % target.buffer.len], .Unordered);
                    var new_target_head = target_head +% 1;
                    var new_tail = tail;
                    num_steal -= 1;

                    while (num_steal > 0) : (num_steal -= 1) {
                        const task = @atomicLoad(*Task, &target.buffer[new_target_head % target.buffer.len], .Unordered);
                        new_target_head +%= 1;
                        @atomicStore(*Task, &self.buffer[new_tail % self.buffer.len], task, .Unordered);
                        new_tail +%= 1;
                    }

                    if (@cmpxchgWeak(
                        usize,
                        &target.head,
                        target_head,
                        new_target_head,
                        .Monotonic,
                        .Monotonic,
                    )) |updated_target_head| {
                        target_head = updated_target_head;
                        continue;
                    }

                    if (tail != new_tail)
                        @atomicStore(usize, &self.tail, new_tail, .Release);
                    return first_task;
                }
            }

            fn inject(
                noalias self: *RunQueue,
                noalias task_stack: ?*Task,
                noalias injected: *bool,
            ) void {
                var head_task: ?*Task = task_stack orelse return;

                var tail = self.tail;
                var head = @atomicLoad(usize, &self.head, .Monotonic);
                assert(tail == head);
                
                var remaining = self.buffer.len;
                while (remaining > 0) : (remaining -= 1) {
                    const task = head_task orelse break;
                    head_task = task.next;
                    @atomicStore(*Task, &self.buffer[tail % self.buffer.len], task, .Unordered);
                    tail +%= 1;
                }

                injected.* = true;
                @atomicStore(usize, &self.tail, tail, .Release);

                if (head_task != null) {
                    var overflow = @atomicLoad(?*Task, &self.overflow, .Monotonic);
                    assert(overflow == null);
                    @atomicStore(?*Task, &self.overflow, head_task, .Release);
                }
            }
        };
    };
};