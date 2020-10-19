// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const assert = std.debug.assert;

pub const Task = struct {
    next: ?*Task = undefined,
    frame: anyframe,

    pub fn init(frame: anyframe) Task {
        return Task{ .frame = frame };
    }

    pub fn execute(self: *Task, worker: *Worker) void {
        resume self.frame;
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
        scheduler.run_queue.push(Batch.from(&task));
        scheduler.worker_pool.resumeWorker(.{ .use_caller_thread = true });

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

    pub fn yield() void {
        const worker = Worker.current orelse {
            std.debug.panic("Cannot yield from outside the thread pool", .{});
        };

        worker.run_next = worker.pollTask() orelse return;
        suspend {
            var task = Task.init(@frame());
            worker.push(Batch.from(&task));
        }
    }

    pub fn shutdown() void {
        const worker = Worker.current orelse {
            std.debug.panic("Cannot shutdown scheduler outside the thread pool", .{});
        };
        worker.scheduler.shutdown();
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

        fn acquire(self: *Lock) void {
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

        fn release(self: *Lock) void {
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

    pub const Scheduler = struct {
        run_queue: RunQueue,
        worker_pool: WorkerPool,

        fn init(self: *Scheduler, max_threads: usize) void {
            self.run_queue = RunQueue{};
            self.worker_pool = WorkerPool{ .max = max_threads };
        }

        pub fn schedule(self: *Scheduler, batch: Batch) void {
            if (batch.isEmpty())
                return;

            self.run_queue.push(batch);
            self.worker_pool.resumeWorker(.{});
        }

        pub fn shutdown(self: *Scheduler) void {
            const worker = Worker.current orelse {
                std.debug.panic("cannot shutdown a Scheduler from outside the thread pool", .{});
            };
            self.worker_pool.shutdown(worker);
        }

        const RunQueue = struct {
            lock: Lock = Lock{},
            tasks: Batch = Batch{},

            fn push(self: *RunQueue, batch: Batch) void {
                if (batch.isEmpty())
                    return;

                self.lock.acquire();
                defer self.lock.release();

                self.tasks.pushMany(batch);
            }

            fn popInto(noalias self: *RunQueue, noalias run_queue: *Worker.RunQueue) ?*Task {
                self.lock.acquire();

                const first_task = self.tasks.pop() orelse {
                    self.lock.release();
                    return null;
                };

                var migrated = Batch{};
                var steal = run_queue.buffer.len;
                while (steal != 0) : (steal -= 1) {
                    const task = self.tasks.pop() orelse break;
                    migrated.push(task);
                }

                self.lock.release();
                
                const overflowed = run_queue.push(migrated);
                assert(overflowed == null);
                return first_task;
            } 
        };

        const WorkerPool = struct {
            lock: Lock = Lock{},
            max: usize,
            running: usize = 0,
            active_head: ?*Worker = null,
            idle_queue: IdleQueue = IdleQueue{},
            shutdown_event: std.AutoResetEvent = std.AutoResetEvent{},
            is_shutdown: bool = false,
            is_waking: bool = false,
            is_notified: bool = false,

            const IdleQueue = struct {
                head: ?*Worker = null,
                
                fn isEmpty(self: IdleQueue) bool {
                    return self.head == null;
                }

                fn push(self: *IdleQueue, worker: *Worker) void {
                    worker.next = self.head;
                    self.head = worker;
                }

                fn pop(self: *IdleQueue) ?*Worker {
                    const worker = self.head orelse return null;
                    self.head = worker.next;
                    return worker;
                }
            };

            const ResumeContext = struct {
                is_waking: bool = false,
                use_caller_thread: bool = false,
            };

            fn resumeWorker(self: *WorkerPool, context: ResumeContext) void {
                self.lock.acquire();
                var retries: usize = 3;
                
                while (true) {
                    if (self.is_shutdown) {
                        self.lock.release();
                        return;
                    }

                    if (!context.is_waking and self.is_waking) {
                        self.is_notified = true;
                        self.lock.release();
                        return;
                    }

                    if (self.running == self.max and self.idle_queue.isEmpty()) {
                        if (context.is_waking) {
                            self.is_waking = false;
                        } else {
                            self.is_notified = true;
                        }
                        self.lock.release();
                        return;
                    }

                    if (self.idle_queue.pop()) |worker| {
                        assert(!std.builtin.single_threaded);
                        self.is_waking = true;
                        self.lock.release();

                        assert(worker.state == .suspended);
                        worker.state = .waking;
                        worker.event.set();
                        return;
                    }

                    @atomicStore(usize, &self.running, self.running + 1, .Monotonic);
                    self.is_waking = true;
                    self.lock.release();

                    var spawn = Worker.Spawn{
                        .lock = Lock{},
                        .scheduler = @fieldParentPtr(Scheduler, "worker_pool", self),
                        .state = .{ .empty = {} },
                    };

                    if (context.use_caller_thread) {
                        Worker.run(&spawn);
                        return;
                    }

                    if (std.builtin.single_threaded)
                        unreachable; // single threaded mode trying to spawn a thread
                        
                    var spawner = Worker.Spawn.Spawner{};
                    spawn.state = .{ .spawning = {} };

                    if (std.Thread.spawn(&spawn, Worker.run)) |thread| {
                        spawn.lock.acquire();
                        return switch (spawn.state) {
                            .spawning => {
                                spawn.state = .{ .spawned = &spawner };
                                spawner.thread = thread;
                                spawn.lock.release();
                                spawner.event.wait();
                            },
                            .waiting => |worker| {
                                worker.thread = thread;
                                worker.event.set();
                            },
                            else => unreachable // invalid spawn state
                        };
                    } else |err| {}

                    self.lock.acquire();
                    @atomicStore(usize, &self.running, self.running - 1, .Monotonic);
                    self.is_waking = false;

                    if (self.is_notified) {
                        self.is_notified = false;
                        if (retries != 0) {
                            retries -= 1;
                            continue;
                        }
                    }

                    self.lock.release();
                    return;
                }
            }

            fn suspendWorker(self: *WorkerPool, worker: *Worker) void {
                self.lock.acquire();

                if (self.is_shutdown) {
                    worker.state = .shutdown;
                    self.lock.release();
                    return;
                }

                if (worker.state == .waking and self.is_notified) {
                    self.is_notified = false;
                    self.lock.release();
                    return;
                }

                if (worker.state == .waking) {
                    assert(self.is_waking);
                    self.is_waking = false;
                }

                worker.state = .suspended;
                self.idle_queue.push(worker);
                self.lock.release();

                worker.event.wait();
            }

            fn shutdown(self: *WorkerPool, worker: *Worker) void {
                self.lock.acquire();

                if (self.is_shutdown) {
                    self.lock.release();
                    return;
                }

                self.is_shutdown = true;
                var idle_queue = self.idle_queue;
                self.idle_queue = IdleQueue{};
                self.lock.release();

                while (idle_queue.pop()) |idle_worker| {
                    idle_worker.state = .shutdown;
                    idle_worker.event.set();
                }
            }

            fn onWorkerBegin(self: *WorkerPool, worker: *Worker) void {
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

            fn onWorkerEnd(self: *WorkerPool, worker: *Worker) void {
                self.lock.acquire();

                self.idle_queue.push(worker);
                @atomicStore(usize, &self.running, self.running - 1, .Monotonic);
                const last_worker = self.running == 0;
                self.lock.release();

                if (last_worker) {
                    self.shutdown_event.set();
                }

                if (worker.thread != null) {
                    worker.event.wait();
                    return;
                }

                self.shutdown_event.wait();

                self.lock.acquire();
                var idle_workers = self.idle_queue;
                self.idle_queue = IdleQueue{};
                self.lock.release();

                while (idle_workers.pop()) |idle_worker| {
                    if (idle_worker.thread) |thread| {
                        idle_worker.event.set();
                        thread.wait();
                    }
                }
            }
        };
    };

    pub const Worker = struct {
        state: State,
        next: ?*Worker,
        target: ?*Worker,
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

        const Spawn = struct {
            lock: Lock,
            scheduler: *Scheduler,
            state: SpawnState,

            const Spawner = struct {
                thread: *std.Thread = undefined,
                event: std.AutoResetEvent = std.AutoResetEvent{},
            };

            const SpawnState = union(enum) {
                empty: void,
                spawning: void,
                spawned: *Spawner,
                waiting: *Worker, 
            };
        };

        threadlocal var current: ?*Worker = null;

        fn run(spawn: *Spawn) void {
            var self = Worker{
                .state = .waking,
                .next = null,
                .target = null,
                .active_next = null,
                .thread = null,
                .scheduler = spawn.scheduler,
                .event = std.AutoResetEvent{},
                .run_next = null,
                .run_queue = RunQueue{},
            };

            const old_current = Worker.current;
            Worker.current = &self;
            defer Worker.current = old_current;

            spawn.lock.acquire();
            switch (spawn.state) {
                .empty => {},
                .waiting => unreachable, // more than one thread on a Worker.Spawn
                .spawning => {
                    std.debug.assert(!std.builtin.single_threaded);
                    spawn.state = .{ .waiting = &self };
                    spawn.lock.release();
                    self.event.wait();
                },
                .spawned => |spawner| {
                    std.debug.assert(!std.builtin.single_threaded);
                    self.thread = spawner.thread;
                    spawner.event.set();
                },
            }

            self.scheduler.worker_pool.onWorkerBegin(&self);
            defer self.scheduler.worker_pool.onWorkerEnd(&self);

            while (true) {
                if (self.pollTask()) |task| {
                    task.execute(&self);
                    continue;
                }

                self.scheduler.worker_pool.suspendWorker(&self);

                switch (self.state) {
                    .shutdown => break,
                    .waking, .running => {},
                    .suspended => unreachable, // worker running when suspended
                }
            }
        }

        fn pollTask(self: *Worker) ?*Task {
            const task = self.findTask() orelse return null;

            if (self.state == .waking) {
                self.scheduler.worker_pool.resumeWorker(.{ .is_waking = true });
                self.state = .running;
            }

            return task;
        }

        fn findTask(self: *Worker) ?*Task {
            if (self.run_next) |next_task| {
                const task = next_task;
                self.run_next = null;
                return task;
            }

            if (self.run_queue.pop()) |task| {
                return task;
            }

            const global_queue = &self.scheduler.run_queue;
            const worker_pool = &self.scheduler.worker_pool;

            var attempts: usize = 2;
            while (attempts > 0) : (attempts -= 1) {

                var active = @atomicLoad(usize, &worker_pool.running, .Monotonic);
                while (active != 0) : (active -= 1) {

                    const target = self.target orelse blk: {
                        const target = @atomicLoad(?*Worker, &worker_pool.active_head, .Monotonic);
                        self.target = target;
                        break :blk target orelse unreachable; // no active_head when trying to steal
                    };

                    self.target = target.next;
                    if (target == self)
                        continue;

                    if (self.run_queue.steal(&target.run_queue)) |task| {
                        return task;
                    }
                }
            }

            if (global_queue.popInto(&self.run_queue)) |task| {
                return task;
            }

            return null;
        }

        fn schedule(self: *Worker, batch: Batch) void {
            if (batch.isEmpty())
                return;

            self.push(batch);
            self.scheduler.worker_pool.resumeWorker(.{});
        }

        fn push(self: *Worker, batch: Batch) void {
            if (self.run_queue.push(batch)) |overflowed| {
                self.scheduler.run_queue.push(overflowed);
            }
        }

        const RunQueue = struct {
            head: usize = 0,
            tail: usize = 0,
            next: ?*Task = null,
            buffer: [256]*Task = undefined,

            fn push(self: *RunQueue, tasks: Batch) ?Batch {
                var batch = tasks;
                var tail = self.tail;
                var head = @atomicLoad(usize, &self.head, .Monotonic);
        
                while (true) {
                    if (batch.isEmpty())
                        return null;

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
                    return overflowed;
                }
            }

            fn pop(self: *RunQueue) ?*Task {
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

                while (true) {
                    if (tail == head)
                        return null;

                    if (@cmpxchgWeak(
                        usize,
                        &self.head,
                        head,
                        head +% 1,
                        .Monotonic,
                        .Monotonic,
                    )) |updated_head| {
                        head = updated_head;
                        continue;
                    }

                    const task = self.buffer[head % self.buffer.len];
                    return task;
                }
            }

            fn steal(noalias self: *RunQueue, noalias target: *RunQueue) ?*Task {
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
                        const next_task = @atomicLoad(?*Task, &target.next, .Monotonic) orelse return null;
                        _ = @cmpxchgWeak(
                            ?*Task,
                            &target.next,
                            next_task,
                            null,
                            .Acquire,
                            .Monotonic,
                        ) orelse return next_task;
                        
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
        };
    };
};