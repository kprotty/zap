const std = @import("std");
const zap = @import("../zap.zig");

const runtime = zap.runtime;
const spinLoopHint = runtime.sync.atomic.spinLoopHint;

// const Lock = runtime.sync.Lock;
const Thread = std.Thread;
const AutoResetEvent = std.AutoResetEvent;

pub const Task = struct {
    next: ?*Task = undefined,
    frame: anyframe,

    pub fn init(frame: anyframe) Task {
        return Task{ .frame = frame };
    }

    fn ReturnTypeOf(comptime asyncFn: anytype) type {
        return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
    }

    pub const RunConfig = struct {
        threads: ?usize = null,
    };

    pub fn run(config: RunConfig, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        const Decorator = struct {
            fn call(fn_args: anytype, task: *Task, result: *?ReturnTypeOf(asyncFn)) void {
                suspend task.* = Task.init(@frame());
                const res = @call(.{}, asyncFn, fn_args);
                suspend {
                    result.* = res;
                    Worker.getCurrent().?.getScheduler().shutdown();
                }
            }
        };

        var task: Task = undefined;
        var result: ?ReturnTypeOf(asyncFn) = null;
        var frame = async Decorator.call(args, &task, &result);

        const num_threads = 
            if (std.builtin.single_threaded) 
                @as(usize, 1)
            else if (config.threads) |threads|
                std.math.max(1, threads)
            else
                Thread.cpuCount() catch 1;

        var scheduler: Scheduler = undefined;
        scheduler.init(num_threads);
        defer scheduler.deinit();

        scheduler.run(Batch.from(&task));

        return result orelse error.Deadlocked;
    }

    pub fn yield() void {
        suspend {
            var task = Task.init(@frame());
            Batch.from(&task).schedule(.{ .use_lifo = false });
        }
    }

    pub fn runConcurrently() void {
        suspend {
            var task = Task.init(@frame());
            Batch.from(&task).schedule(.{ .use_lifo = true });
        }
    }

    pub fn schedule(self: *Task) void {
        Batch.from(self).schedule(.{});
    }

    pub fn scheduleNext(self: *Task) void {
        Batch.from(self).schedule(.{ .use_next = true });
    }

    pub const Batch = struct {
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

        pub fn push(self: *Batch, task: *Task) void {
            self.pushMany(Batch.from(task));
        }

        pub fn pushMany(self: *Batch, other: Batch) void {
            if (self.isEmpty()) {
                self.* = other;
            } else if (!other.isEmpty()) {
                self.tail.next = other.head;
                self.tail = other.tail;
            }
        }

        pub fn pushFront(self: *Batch, task: *Task) void {
            self.pushFrontMany(Batch.from(task));
        }

        pub fn pushFrontMany(self: *Batch, other: Batch) void {
            if (self.isEmpty()) {
                self.* = other;
            } else if (!other.isEmpty()) {
                other.tail.next = self.head;
                self.head = other.head;
            }
        }

        pub fn pop(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }

        pub fn schedule(self: Batch, hints: Worker.ScheduleHints) void {
            if (self.isEmpty())
                return;

            const worker = Worker.getCurrent() orelse @panic("Batch.schedule when not inside scheduler");
            worker.schedule(self, hints);
        }
    };

    pub const Worker = struct {
        aligned: void align(@as(usize, @as(@TagType(Scheduler.State), 0)) + 1) = undefined,
        state: State = .waking,
        scheduler: *Scheduler,
        thread: ?*Thread,
        idle_next: ?*Worker = null,
        active_next: ?*Worker = null,
        target_worker: ?*Worker = null,
        event: AutoResetEvent = AutoResetEvent{},
        runq_tick: usize = 0,
        runq_head: usize = 0,
        runq_tail: usize = 0,
        runq_lifo: ?*Task = null,
        runq_next: ?*Task = null,
        runq_overflow: ?*Task = null,
        runq_buffer: [256]*Task = undefined,

        const State = enum {
            waking,
            running,
            suspended,
            stopping,
            shutdown,
        };

        threadlocal var current: ?*Worker = null;

        pub fn getCurrent() ?*Worker {
            return Worker.current;
        }

        fn setCurrent(worker: ?*Worker) void {
            Worker.current = worker;
        }

        pub fn getScheduler(self: *Worker) *Scheduler {
            return self.scheduler;
        }

        pub const ScheduleHints = struct {
            use_lifo: bool = false,
            use_next: bool = false,
        };

        pub fn schedule(self: *Worker, tasks: Batch, hints: ScheduleHints) void {
            var batch = tasks;
            if (batch.isEmpty())
                return;

            if (hints.use_next) {
                if (self.runq_next) |old_next|
                    batch.push(old_next);
                self.runq_next = batch.pop();
                if (batch.isEmpty())
                    return;
            }

            if (hints.use_lifo) {
                const new_lifo = batch.pop();
                var runq_lifo = @atomicLoad(?*Task, &self.runq_lifo, .Monotonic);

                while (true) {
                    const old_lifo = runq_lifo orelse {
                        @atomicStore(?*Task, &self.runq_lifo, new_lifo, .Release);
                        break;
                    };

                    runq_lifo = @cmpxchgWeak(
                        ?*Task,
                        &self.runq_lifo,
                        old_lifo,
                        new_lifo,
                        .Release,
                        .Monotonic,
                    ) orelse {
                        batch.pushFront(old_lifo);
                        break;
                    };
                }
            }

            var tail = self.runq_tail;
            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);

            while (!batch.isEmpty()) {
                var remaining = self.runq_buffer.len - (tail -% head);
                if (remaining > 0) {
                    while (remaining > 0) : (remaining -= 1) {
                        const task = batch.pop() orelse break;
                        @atomicStore(*Task, &self.runq_buffer[tail % self.runq_buffer.len], task, .Unordered);
                        tail +%= 1;
                    }

                    @atomicStore(usize, &self.runq_tail, tail, .Release);
                    head = @atomicLoad(usize, &self.runq_head, .Monotonic);
                    continue;
                }

                const new_head = head +% (self.runq_buffer.len / 2);
                if (@cmpxchgWeak(
                    usize,
                    &self.runq_head,
                    head,
                    new_head,
                    .Monotonic,
                    .Monotonic,
                )) |updated| {
                    head = updated;
                    continue;
                }

                var overflowed = Batch{};
                while (head != new_head) : (head +%= 1) {
                    const task = self.runq_buffer[head % self.runq_buffer.len];
                    overflowed.push(task);
                }
                batch.pushFrontMany(overflowed);
                
                var overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
                while (true) {
                    batch.tail.next = overflow;

                    if (overflow == null) {
                        @atomicStore(?*Task, &self.runq_overflow, batch.head, .Release);
                        break;
                    }

                    overflow = @cmpxchgWeak(
                        ?*Task,
                        &self.runq_overflow,
                        overflow,
                        batch.head,
                        .Release,
                        .Monotonic,
                    ) orelse break;
                }

                batch = Batch{};
                break;
            }

            const scheduler = self.getScheduler();
            scheduler.resumeWorker(false);
        }

        fn poll(self: *Worker, scheduler: *Scheduler, injected: *bool) ?*Task {
            // TODO: if single-threaded, poll for io/timers (non-blocking)

            if (self.runq_next) |next| {
                const task = next;
                self.runq_next = null;
                return task;
            }

            if (self.runq_tick % 31 == 0) {
                var overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
                while (overflow) |first_task| {
                    overflow = @cmpxchgWeak(
                        ?*Task,
                        &self.runq_overflow,
                        first_task,
                        null,
                        .Monotonic,
                        .Monotonic,
                    ) orelse {
                        if (first_task.next) |next| {
                            injected.* = true;
                            @atomicStore(?*Task, &self.runq_overflow, next, .Release);
                        }
                        return first_task;
                    };
                }
            }

            var lifo = @atomicLoad(?*Task, &self.runq_lifo, .Monotonic);
            while (lifo) |task| {
                lifo = @cmpxchgWeak(
                    ?*Task,
                    &self.runq_lifo,
                    lifo,
                    null,
                    .Monotonic,
                    .Monotonic,
                ) orelse return task;
            }

            var tail = self.runq_tail;
            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            while (tail != head) {
                head = @cmpxchgWeak(
                    usize,
                    &self.runq_head,
                    head,
                    head +% 1,
                    .Monotonic,
                    .Monotonic,
                ) orelse return self.runq_buffer[head % self.runq_buffer.len];
            }

            var overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
            while (overflow) |first_task| {
                overflow = @cmpxchgWeak(
                    ?*Task,
                    &self.runq_overflow,
                    first_task,
                    null,
                    .Monotonic,
                    .Monotonic,
                ) orelse {
                    self.inject(first_task.next, tail, injected);
                    return first_task;
                };
            }

            var steal_attempts: usize = 1;
            while (steal_attempts > 0) : (steal_attempts -= 1) {
                
                var active_workers = @atomicLoad(usize, &scheduler.active_workers, .Monotonic);
                while (active_workers > 0) : (active_workers -= 1) {

                    const target = self.target_worker orelse blk: {
                        const target = @atomicLoad(?*Worker, &scheduler.active_queue, .Acquire);
                        self.target_worker = target;
                        break :blk (target orelse @panic("no active workers when trying to steal"));
                    };

                    self.target_worker = target.active_next;
                    if (target == self)
                        continue;

                    var target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                    while (true) {
                        const target_tail = @atomicLoad(usize, &target.runq_tail, .Acquire);

                        const target_size = target_tail -% target_head;
                        if (target_size > target.runq_buffer.len) {
                            spinLoopHint();
                            target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                            continue;
                        }

                        var steal = target_size - (target_size / 2);
                        if (steal == 0) {
                            if (@atomicLoad(?*Task, &target.runq_overflow, .Monotonic)) |first_task| {
                                _ = @cmpxchgWeak(
                                    ?*Task,
                                    &target.runq_overflow,
                                    first_task,
                                    null,
                                    .Acquire,
                                    .Monotonic,
                                ) orelse {
                                    self.inject(first_task.next, tail, injected);
                                    return first_task;
                                };
                            } else if (@atomicLoad(?*Task, &target.runq_lifo, .Monotonic)) |task| {
                                _ = @cmpxchgWeak(
                                    ?*Task,
                                    &target.runq_lifo,
                                    task,
                                    null,
                                    .Acquire,
                                    .Monotonic,
                                ) orelse return task;
                            } else {
                                break;
                            }

                            spinLoopHint();
                            target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                            continue;
                        }

                        const first_task = @atomicLoad(*Task, &target.runq_buffer[target_head % target.runq_buffer.len], .Unordered);
                        var new_target_head = target_head +% 1;
                        var new_tail = tail;
                        steal -= 1;

                        while (steal > 0) : (steal -= 1) {
                            const task = @atomicLoad(*Task, &target.runq_buffer[new_target_head % target.runq_buffer.len], .Unordered);
                            new_target_head +%= 1;
                            @atomicStore(*Task, &self.runq_buffer[new_tail % self.runq_buffer.len], task, .Unordered);
                            new_tail +%= 1;
                        }

                        if (@cmpxchgWeak(
                            usize,
                            &target.runq_head,
                            target_head,
                            new_target_head,
                            .Monotonic,
                            .Monotonic,
                        )) |updated| {
                            target_head = updated;
                            continue;
                        }

                        if (new_tail != tail)
                            @atomicStore(usize, &self.runq_tail, new_tail, .Release);
                        return first_task;
                    }
                }
            }
            
            var run_queue = @atomicLoad(?*Task, &scheduler.run_queue, .Monotonic);
            while (run_queue) |first_task| {
                run_queue = @cmpxchgWeak(
                    ?*Task,
                    &scheduler.run_queue,
                    first_task,
                    null,
                    .Acquire,
                    .Monotonic,
                ) orelse {
                    self.inject(first_task.next, tail, injected);
                    return first_task;
                };
            }

            // TODO: if single-threaded, poll for io/timers (blocking)
            return null;
        }

        fn inject(self: *Worker, run_queue: ?*Task, tail: usize, injected: *bool) void {
            var new_tail = tail;
            var runq: ?*Task = run_queue orelse return;
            
            var remaining: usize = self.runq_buffer.len;
            while (remaining > 0) : (remaining -= 1) {
                const task = runq orelse break;
                runq = task.next;
                @atomicStore(*Task, &self.runq_buffer[new_tail % self.runq_buffer.len], task, .Unordered);
                new_tail +%= 1;
            }

            injected.* = true;
            @atomicStore(usize, &self.runq_tail, new_tail, .Release);

            if (runq != null)
                @atomicStore(?*Task, &self.runq_overflow, runq, .Release);
        }

        const SpawnInfo = struct {
            scheduler: *Scheduler,
            thread: ?*Thread = null,
            thread_event: AutoResetEvent = AutoResetEvent{},
            spawn_event: AutoResetEvent = AutoResetEvent{},
        };

        fn spawn(scheduler: *Scheduler, use_caller_thread: bool) bool {
            var spawn_info = SpawnInfo{ .scheduler = scheduler };

            if (std.builtin.single_threaded or use_caller_thread) {
                spawn_info.thread_event.set();
                Worker.run(&spawn_info);
                return true;
            }

            spawn_info.thread = Thread.spawn(&spawn_info, Worker.run) catch return false;
            spawn_info.thread_event.set();
            spawn_info.spawn_event.wait();
            return true;
        }

        fn run(spawn_info: *SpawnInfo) void {
            const scheduler = spawn_info.scheduler;
            spawn_info.thread_event.wait();
            const thread = spawn_info.thread;
            spawn_info.spawn_event.set();

            var self = Worker{
                .scheduler = scheduler,
                .thread = thread,
            };

            if (thread == null)
                scheduler.main_worker = &self;

            const old_current = Worker.getCurrent();
            Worker.setCurrent(&self);
            defer Worker.setCurrent(old_current);

            var active_queue = @atomicLoad(?*Worker, &scheduler.active_queue, .Monotonic);
            while (true) {
                self.active_next = active_queue;
                active_queue = @cmpxchgWeak(
                    ?*Worker,
                    &scheduler.active_queue,
                    active_queue,
                    &self,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }

            self.runq_tick = @ptrToInt(&self);
            while (true) {
                const should_poll = switch (self.state) {
                    .running, .waking => true,
                    .suspended => @panic("worker trying to poll when suspended"),
                    .stopping => false,
                    .shutdown => break,
                };

                if (should_poll) {
                    var injected = false;
                    if (self.poll(scheduler, &injected)) |task| {
                        if (injected or self.state == .waking)
                            scheduler.resumeWorker(self.state == .waking);
                        self.state = .running;
                        self.runq_tick +%= 1;
                        resume task.frame;
                        continue;
                    }
                }

                scheduler.suspendWorker(&self);
            }
        }
    };

    pub const Scheduler = struct {
        idle_queue: IdleQueue = IdleQueue{ .value = @enumToInt(State.ready) },
        run_queue: ?*Task = null,
        active_queue: ?*Worker = null,
        active_workers: usize = 0,
        max_workers: usize,
        main_worker: ?*Worker = null,

        const State = enum(u3) {
            ready,
            waking,
            waking_notified,
            suspend_notified,
            shutdown,
        };

        const IdleQueue = switch (std.builtin.arch) {
            .i386, .x86_64 => extern struct {
                value: usize align(@alignOf(DoubleWord)),
                aba_tag: usize = 0,

                const DoubleWord = std.meta.Int(.unsigned, std.meta.bitCount(usize) * 2);

                fn load(
                    self: *const IdleQueue,
                    comptime order: std.builtin.AtomicOrder,
                ) IdleQueue {
                    return IdleQueue{
                        .value = @atomicLoad(usize, &self.value, order),
                        .aba_tag = @atomicLoad(usize, &self.aba_tag, .Monotonic),
                    };
                }

                fn tryCompareAndSwap(
                    self: *IdleQueue,
                    compare: IdleQueue,
                    exchange: usize,
                    comptime success: std.builtin.AtomicOrder,
                    comptime failure: std.builtin.AtomicOrder,
                ) ?IdleQueue {
                    const value = @cmpxchgWeak(
                        DoubleWord,
                        @ptrCast(*DoubleWord, self),
                        @bitCast(DoubleWord, compare),
                        @bitCast(DoubleWord, IdleQueue{
                            .value = exchange,
                            .aba_tag = compare.aba_tag +% 1,
                        }),
                        success,
                        failure,
                    ) orelse return null;
                    return @bitCast(IdleQueue, value);
                }
            },
            else => extern struct {
                value: usize,

                fn load(
                    self: *const IdleQueue,
                    comptime order: std.builtin.AtomicOrder,
                ) IdleQueue {
                    return IdleQueue{ .value = @atomicLoad(usize, &self.value, order) };
                }

                fn tryCompareAndSwap(
                    self: *IdleQueue,
                    compare: IdleQueue,
                    exchange: usize,
                    comptime success: std.builtin.AtomicOrder,
                    comptime failure: std.builtin.AtomicOrder,
                ) ?IdleQueue {
                    const value = @cmpxchgWeak(
                        usize,
                        &self.value,
                        compare.value,
                        exchange,
                        success,
                        failure,
                    ) orelse return null;
                    return IdleQueue{ .value = value };
                }
            },
        };

        pub fn init(self: *Scheduler, num_threads: usize) void {
            self.* = Scheduler{ .max_workers = num_threads };
        }

        pub fn deinit(self: *Scheduler) void {
            self.* = undefined;
        }

        pub fn run(self: *Scheduler, batch: Batch) void {
            if (batch.isEmpty())
                return;
            
            batch.tail.next = self.run_queue;
            self.run_queue = batch.head;

            self.resumeWorker(false);
        }

        fn resumeWorker(self: *Scheduler, is_caller_waking: bool) void {
            var waking_attempts: u8 = 5;
            var is_waking = is_caller_waking;
            var idle_queue = self.idle_queue.load(.Monotonic);

            while (true) {
                const idle_ptr = idle_queue.value & ~@as(usize, ~@as(@TagType(State), 0));
                const idle_state = @intToEnum(State, @truncate(@TagType(State), idle_queue.value));

                if (idle_state == .shutdown)
                    return;

                if (
                    (!is_waking and idle_state == .ready) or
                    (is_waking and idle_state == .waking_notified and waking_attempts > 0)
                ) {
                    if (@intToPtr(?*Worker, idle_ptr)) |worker| {
                        @fence(.Acquire);
                        const next_worker = @atomicLoad(?*Worker, &worker.idle_next, .Unordered);
                        if (self.idle_queue.tryCompareAndSwap(
                            idle_queue,
                            @ptrToInt(next_worker) | @enumToInt(State.waking),
                            .Monotonic,
                            .Monotonic,
                        )) |updated| {
                            idle_queue = updated;
                            continue;
                        }

                        if (worker.state != .suspended)
                            @panic("resuming worker with invalid state");
                        worker.state = .waking;
                        worker.event.set();
                        return;
                    }

                    const active_workers = @atomicLoad(usize, &self.active_workers, .Monotonic);
                    if (active_workers < self.max_workers) {
                        if (self.idle_queue.tryCompareAndSwap(
                            idle_queue,
                            @enumToInt(State.waking),
                            .Monotonic,
                            .Monotonic,
                        )) |updated| {
                            idle_queue = updated;
                            continue;
                        }

                        @atomicStore(usize, &self.active_workers, active_workers + 1, .Monotonic);
                        if (Worker.spawn(self, active_workers == 0)) {
                            return;
                        }

                        @atomicStore(usize, &self.active_workers, active_workers, .Monotonic);
                        waking_attempts -= 1;
                        is_waking = true;

                        spinLoopHint();
                        idle_queue = self.idle_queue.load(.Monotonic);
                        continue;
                    }
                }

                const new_state = blk: {
                    if (is_waking)
                        break :blk State.ready;
                    if (idle_state == .waking)
                        break :blk State.waking_notified;
                    if (idle_state == .ready)
                        break :blk State.suspend_notified;
                    return;
                };

                idle_queue = self.idle_queue.tryCompareAndSwap(
                    idle_queue,
                    idle_ptr | @enumToInt(new_state),
                    .Monotonic,
                    .Monotonic,
                ) orelse return;
            }   
        }

        fn suspendWorker(self: *Scheduler, worker: *Worker) void {
            const old_worker_state = worker.state;
            var idle_queue = self.idle_queue.load(.Monotonic);

            while (true) {
                const idle_ptr = idle_queue.value & ~@as(usize, ~@as(@TagType(State), 0));
                const idle_state = @intToEnum(State, @truncate(@TagType(State), idle_queue.value));

                if (
                    (idle_state == .suspend_notified) or
                    (old_worker_state == .waking and idle_state == .waking_notified)
                ) {
                    const new_state: State = switch (idle_state) {
                        .waking_notified => .waking,
                        .suspend_notified => .ready,
                        else => unreachable,
                    };

                    idle_queue = self.idle_queue.tryCompareAndSwap(
                        idle_queue,
                        idle_ptr | @enumToInt(new_state),
                        .Monotonic,
                        .Monotonic,
                    ) orelse {
                        worker.state = old_worker_state;
                        return;
                    };

                    continue;
                }

                worker.state = if (idle_state == .shutdown) .stopping else .suspended;
                @atomicStore(?*Worker, &worker.idle_next, @intToPtr(?*Worker, idle_ptr), .Unordered);

                if (self.idle_queue.tryCompareAndSwap(
                    idle_queue,
                    @ptrToInt(worker) | @enumToInt(idle_state),
                    .Release,
                    .Monotonic,
                )) |updated| {
                    idle_queue = updated;
                    continue;
                }

                const is_main_worker = worker.thread == null;
                if (idle_state == .shutdown) {
                    var is_last_worker: bool = undefined;
                    if (is_main_worker) {
                        self.main_worker = worker;
                        is_last_worker = @atomicRmw(usize, &self.active_workers, .Sub, 1, .Release) == 1;
                    } else {
                        is_last_worker = @atomicRmw(usize, &self.active_workers, .Sub, 1, .Acquire) == 1;
                    }
                    if (is_last_worker) {
                        const main_worker = self.main_worker orelse @panic("no main worker when shutting down");
                        main_worker.event.set();
                    }
                }

                worker.event.wait();

                if (idle_state == .shutdown and is_main_worker) {
                    idle_queue = self.idle_queue.load(.Acquire);

                    var idle_worker = @intToPtr(?*Worker, idle_queue.value & ~@as(usize, ~@as(@TagType(State), 0)));
                    while (idle_worker) |new_idle_worker| {
                        const shutdown_worker = new_idle_worker;
                        idle_worker = shutdown_worker.idle_next;

                        if (shutdown_worker.state != .stopping)
                            @panic("worker shutting down with an invalid state");
                        shutdown_worker.state = .shutdown;

                        const shutdown_thread = shutdown_worker.thread;
                        shutdown_worker.event.set();

                        if (shutdown_thread) |thread|
                            thread.wait();
                    }
                }

                return;
            }
        }

        pub fn shutdown(self: *Scheduler) void {
            var idle_queue = self.idle_queue.load(.Monotonic);

            while (true) {
                const idle_state = @intToEnum(State, @truncate(@TagType(State), idle_queue.value));
                if (idle_state == .shutdown)
                    return;

                if (self.idle_queue.tryCompareAndSwap(
                    idle_queue,
                    @enumToInt(State.shutdown),
                    .Acquire,
                    .Monotonic,
                )) |updated| {
                    idle_queue = updated;
                    continue;
                }

                var idle_worker = @intToPtr(?*Worker, idle_queue.value & ~@as(usize, ~@as(@TagType(State), 0)));
                while (idle_worker) |new_idle_worker| {
                    const stopping_worker = new_idle_worker;
                    idle_worker = stopping_worker.idle_next;

                    if (stopping_worker.state != .suspended)
                        @panic("stopping worker with invalid state");

                    stopping_worker.state = .stopping;
                    stopping_worker.event.set();
                }

                return;
            }
        }
    };
};
