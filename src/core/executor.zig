const std = @import("std");
const core = @import("./core.zig");

const fence = core.sync.atomic.fence;
const Atomic = core.sync.atomic.Atomic;
const Ordering = core.sync.atomic.Ordering;
const spinLoopHint = core.sync.atomic.spinLoopHint;

pub const Task = extern struct {
    next: ?*Task = undefined,

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
    };
};

pub const Worker = struct {
    sched_state: usize align(@as(usize, @as(@TagType(Scheduler.State), 0)) + 1),
    state: Atomic(State) = Atomic(State).init(.waking),
    idle_next: ?*Worker = null,
    idle_position: Atomic(usize) = Atomic(usize).init(0),
    active_next: ?*Worker = null,
    target_worker: ?*Worker = null,
    runq_tick: usize = 0,
    runq_next: ?*Task = null,
    runq_head: Atomic(usize) = Atomic(usize).init(0),
    runq_tail: Atomic(usize) = Atomic(usize).init(0),
    runq_lifo: Atomic(?*Task) = Atomic(?*Task).init(null),
    runq_overflow: Atomic(?*Task) = Atomic(?*Task).init(null),
    runq_buffer: [256]Atomic(*Task) = undefined,

    const State = enum(usize) {
        waking = 0,
        running,
        suspended,
        stopping,
        joining,
        shutdown,
    };

    pub fn init(self: *Worker, scheduler: *Scheduler, is_main_worker: bool) void {
        self.* = Worker{
            .runq_tick = @ptrToInt(self),
            .sched_state = @ptrToInt(scheduler) | @boolToInt(is_main_worker),
        };

        if (is_main_worker) {
            scheduler.main_worker = self;
        }

        var active_queue = scheduler.active_queue.load(.relaxed);
        while (true) {
            self.active_next = active_queue;
            active_queue = scheduler.active_queue.tryCompareAndSwap(
                active_queue,
                self,
                .release,
                .relaxed,
            ) orelse break;
        }
    }

    pub const Poll = union(enum) {
        executed: *Task,
        suspended: SuspendIntent,
        shutdown: void,

        pub const SuspendIntent = enum {
            first,
            last,
            normal,
            retry,
        };
    };

    pub fn poll(self: *Worker) Poll {
        const scheduler = self.getScheduler();
        while (true) {
            const state = self.state.load(.unordered);
            const is_waking = state == .waking;

            switch (state) {
                .running, .waking => {
                    var injected = false;
                    if (self.pop(scheduler, &injected)) |task| {
                        if (injected or is_waking) {
                            scheduler.resumeWorker(is_waking);
                            if (is_waking) {
                                self.state.store(.running, .unordered);
                            }
                        }
                        
                        self.runq_tick +%= 1;
                        return .{ .executed = task };
                    }
                },
                .suspended => {
                    @panic("worker polled while still suspended");
                },
                .stopping => {},
                .joining => {
                    scheduler.join();
                    return .shutdown;
                },
                .shutdown => {
                    return .shutdown;
                },
            }

            const suspend_intent = scheduler.suspendWorker(self, state);
            return .{ .suspended = suspend_intent };
        }
    }

    pub fn getScheduler(self: *const Worker) *Scheduler {
        @setRuntimeSafety(false);
        const sched_ptr = self.sched_state & ~@as(usize, 1);
        return @intToPtr(*Scheduler, sched_ptr);
    }

    pub fn isMainWorker(self: *const Worker) bool {
        return self.sched_state & 1 != 0;
    }

    pub const ScheduleHints = struct {
        use_lifo: bool = false,
        use_next: bool = false,
    };

    pub fn schedule(self: *Worker, tasks: Task.Batch, hints: ScheduleHints) void {
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
            var runq_lifo = self.runq_lifo.load(.relaxed);

            while (true) {
                const old_lifo = runq_lifo orelse {
                    self.runq_lifo.store(new_lifo, .release);
                    break;
                };

                runq_lifo = self.runq_lifo.tryCompareAndSwap(
                    old_lifo,
                    new_lifo,
                    .release,
                    .relaxed,
                ) orelse {
                    batch.pushFront(old_lifo);
                    break;
                };
            }
        }

        var tail = self.runq_tail.get();
        var head = self.runq_head.load(.relaxed);

        while (!batch.isEmpty()) {
            var remaining = self.runq_buffer.len - (tail -% head);
            if (remaining > 0) {
                while (remaining > 0) : (remaining -= 1) {
                    const task = batch.pop() orelse break;
                    self.runq_buffer[tail % self.runq_buffer.len].store(task, .unordered);
                    tail +%= 1;
                }

                self.runq_tail.store(tail, .release);
                head = self.runq_head.load(.relaxed);
                continue;
            }

            const new_head = head +% (self.runq_buffer.len / 2);
            if (self.runq_head.tryCompareAndSwap(
                head,
                new_head,
                .relaxed,
                .relaxed,
            )) |updated| {
                head = updated;
                continue;
            }

            var overflowed = Task.Batch{};
            while (head != new_head) : (head +%= 1) {
                const task = self.runq_buffer[head % self.runq_buffer.len].get();
                overflowed.push(task);
            }

            batch.pushFrontMany(overflowed);
            self.pushOverflow(batch);
            break;
        }

        const scheduler = self.getScheduler();
        scheduler.resumeWorker(false);
    }

    fn pushOverflow(self: *Worker, batch: Task.Batch) void {
        if (batch.isEmpty())
            return;

        var overflow = self.runq_overflow.load(.relaxed);
        while (true) {
            batch.tail.next = overflow;

            if (overflow == null) {
                self.runq_overflow.store(batch.head, .release);
                break;
            }

            overflow = self.runq_overflow.tryCompareAndSwap(
                overflow,
                batch.head,
                .release,
                .relaxed,
            ) orelse break;
        }
    }

    fn pop(self: *Worker, scheduler: *Scheduler, injected: *bool) ?*Task {
        var polled = Task.Batch{};
        scheduler.platform.call(.{
            .polled = .{
                .worker = self,
                .batch = &polled,
                .intent = .first,
            },
        });

        if (polled.pop()) |first_task| {
            if (!polled.isEmpty()) {
                injected.* = true;
                self.pushOverflow(polled);
            }
            return first_task;
        }

        if (self.runq_next) |next| {
            const task = next;
            self.runq_next = null;
            return task;
        }

        if (self.runq_tick % 61 == 0) {
            var overflow = self.runq_overflow.load(.relaxed);
            while (overflow) |first_task| {
                overflow = self.runq_overflow.tryCompareAndSwap(
                    first_task,
                    null,
                    .relaxed,
                    .relaxed,
                ) orelse {
                    if (first_task.next) |next| {
                        injected.* = true;
                        self.runq_overflow.store(next, .release);
                    }
                    return first_task;
                };
            }
        }

        var lifo = self.runq_lifo.load(.relaxed);
        while (lifo) |task| {
            lifo = self.runq_lifo.tryCompareAndSwap(
                lifo,
                null,
                .relaxed,
                .relaxed,
            ) orelse return task;
        }

        var tail = self.runq_tail.get();
        var head = self.runq_head.load(.relaxed);
        while (tail != head) {
            head = self.runq_head.tryCompareAndSwap(
                head,
                head +% 1,
                .relaxed,
                .relaxed,
            ) orelse return self.runq_buffer[head % self.runq_buffer.len].get();
        }

        var overflow = self.runq_overflow.load(.relaxed);
        while (overflow) |first_task| {
            overflow = self.runq_overflow.tryCompareAndSwap(
                first_task,
                null,
                .relaxed,
                .relaxed,
            ) orelse {
                self.inject(first_task.next, tail, injected);
                return first_task;
            };
        }

        var steal_attempts: usize = 1 + (self.runq_tick % 4);
        while (steal_attempts > 0) : (steal_attempts -= 1) {
            
            var active_workers = scheduler.active_workers.load(.relaxed);
            while (active_workers > 0) : (active_workers -= 1) {

                const target = self.target_worker orelse blk: {
                    const target = scheduler.active_queue.load(.acquire);
                    self.target_worker = target;
                    break :blk (target orelse @panic("no active workers when trying to steal"));
                };

                self.target_worker = target.active_next;
                if (target == self)
                    continue;

                var target_head = target.runq_head.load(.relaxed);
                while (true) {
                    const target_tail = target.runq_tail.load(.acquire);

                    const target_size = target_tail -% target_head;
                    if (target_size > target.runq_buffer.len) {
                        spinLoopHint();
                        target_head = target.runq_head.load(.relaxed);
                        continue;
                    }

                    var steal = target_size - (target_size / 2);
                    if (steal == 0) {
                        if (target.runq_overflow.load(.relaxed)) |first_task| {
                            _ = target.runq_overflow.tryCompareAndSwap(
                                first_task,
                                null,
                                .acquire,
                                .relaxed,
                            ) orelse {
                                self.inject(first_task.next, tail, injected);
                                return first_task;
                            };
                        } else if (target.runq_lifo.load(.relaxed)) |task| {
                            _ = target.runq_lifo.tryCompareAndSwap(
                                task,
                                null,
                                .acquire,
                                .relaxed,
                            ) orelse return task;
                        } else {
                            break;
                        }

                        spinLoopHint();
                        target_head = target.runq_head.load(.relaxed);
                        continue;
                    }

                    const first_task = target.runq_buffer[target_head % target.runq_buffer.len].load(.unordered);
                    var new_target_head = target_head +% 1;
                    var new_tail = tail;
                    steal -= 1;

                    while (steal > 0) : (steal -= 1) {
                        const task = target.runq_buffer[new_target_head % target.runq_buffer.len].load(.unordered);
                        new_target_head +%= 1;
                        self.runq_buffer[new_tail % self.runq_buffer.len].store(task, .unordered);
                        new_tail +%= 1;
                    }

                    if (target.runq_head.tryCompareAndSwap(
                        target_head,
                        new_target_head,
                        .relaxed,
                        .relaxed,
                    )) |updated| {
                        target_head = updated;
                        continue;
                    }

                    if (new_tail != tail)
                        self.runq_tail.store(new_tail, .release);
                    return first_task;
                }
            }
        }
        
        var run_queue = scheduler.run_queue.load(.relaxed);
        while (run_queue) |first_task| {
            run_queue = scheduler.run_queue.tryCompareAndSwap(
                first_task,
                null,
                .acquire,
                .relaxed,
            ) orelse {
                self.inject(first_task.next, tail, injected);
                return first_task;
            };
        }

        scheduler.platform.call(.{
            .polled = .{
                .worker = self,
                .batch = &polled,
                .intent = .last,
            },
        });

        if (polled.pop()) |first_task| {
            if (!polled.isEmpty()) {
                injected.* = true;
                self.pushOverflow(polled);
            }
            return first_task;
        }

        return null;
    }

    fn inject(self: *Worker, run_queue: ?*Task, tail: usize, injected: *bool) void {
        var new_tail = tail;
        var runq: ?*Task = run_queue orelse return;
        
        var remaining: usize = self.runq_buffer.len;
        while (remaining > 0) : (remaining -= 1) {
            const task = runq orelse break;
            runq = task.next;
            self.runq_buffer[new_tail % self.runq_buffer.len].store(task, .unordered);
            new_tail +%= 1;
        }

        injected.* = true;
        self.runq_tail.store(new_tail, .release);

        if (runq != null)
            self.runq_overflow.store(runq, .release);
    }
};

pub const Scheduler = struct {
    idle_queue: IdleQueue = IdleQueue{ .value = Atomic(usize).init(@enumToInt(State.ready)) },
    run_queue: Atomic(?*Task) = Atomic(?*Task).init(null),
    active_queue: Atomic(?*Worker) = Atomic(?*Worker).init(null),
    active_workers: Atomic(usize) = Atomic(usize).init(0),
    max_workers: usize,
    main_worker: ?*Worker = null,
    platform: *Platform,

    const State = enum(u3) {
        ready,
        waking,
        waking_notified,
        suspend_notified,
        shutdown,
    };

    pub fn init(self: *Scheduler, platform: *Platform, num_threads: usize) void {
        self.* = Scheduler{
            .max_workers = num_threads,
            .platform = platform,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.* = undefined;
    }

    pub fn run(self: *Scheduler, batch: Task.Batch) void {
        if (batch.isEmpty())
            return;
        
        batch.tail.next = self.run_queue.get();
        self.run_queue.set(batch.head);

        self.resumeWorker(false);
    }

    fn resumeWorker(self: *Scheduler, is_caller_waking: bool) void {
        var waking_attempts: u8 = 5;
        var is_waking = is_caller_waking;
        var idle_queue = self.idle_queue.load(.relaxed);

        while (true) {
            const idle_ptr = idle_queue.value.get() & ~@as(usize, ~@as(@TagType(State), 0));
            const idle_state = @intToEnum(State, @truncate(@TagType(State), idle_queue.value.get()));

            if (idle_state == .shutdown)
                return;

            if (
                (!is_waking and idle_state == .ready) or
                (is_waking and idle_state == .waking_notified and waking_attempts > 0)
            ) {
                const active_workers = self.active_workers.load(.relaxed);

                if (@intToPtr(?*Worker, idle_ptr)) |worker| {
                    fence(.acquire);
                    const next_worker = worker.idle_next;
                    if (self.idle_queue.tryCompareAndSwap(
                        idle_queue,
                        @ptrToInt(next_worker) | @enumToInt(State.waking),
                        .relaxed,
                        .relaxed,
                    )) |updated| {
                        idle_queue = updated;
                        continue;
                    }

                    const worker_state = worker.state.load(.unordered);
                    if (worker_state != .suspended)
                        @panic("resuming worker with invalid state");
                    worker.state.store(.waking, .unordered);

                    const idle_position = worker.idle_position.load(.unordered);
                    self.platform.call(.{
                        .resumed = .{
                            .scheduler = self,
                            .worker = worker,
                            .intent = blk: {
                                if (idle_position == 0) 
                                    break :blk .first;
                                if (active_workers > 0 and idle_position == active_workers - 1)
                                    break :blk .last;
                                break :blk .normal;
                            },
                        },
                    });

                    return;
                }

                if (active_workers < self.max_workers) {
                    if (self.idle_queue.tryCompareAndSwap(
                        idle_queue,
                        @enumToInt(State.waking),
                        .relaxed,
                        .relaxed,
                    )) |updated| {
                        idle_queue = updated;
                        continue;
                    }

                    self.active_workers.store(active_workers + 1, .relaxed);
                    var did_spawn = false;
                    self.platform.call(.{
                        .spawned = .{
                            .scheduler = self,
                            .succeeded = &did_spawn,
                            .intent = blk: {
                                if (active_workers == 0) 
                                    break :blk .first;
                                if (active_workers == self.max_workers - 1)
                                    break :blk .last;
                                break :blk .normal;
                            },
                        },
                    });
                    if (did_spawn) {
                        return;
                    }

                    self.active_workers.store(active_workers, .relaxed);
                    waking_attempts -= 1;
                    is_waking = true;

                    spinLoopHint();
                    idle_queue = self.idle_queue.load(.relaxed);
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
                .relaxed,
                .relaxed,
            ) orelse return;
        }
    }

    fn suspendWorker(self: *Scheduler, worker: *Worker, worker_state: Worker.State) Worker.Poll.SuspendIntent {
        const is_main_worker = worker.isMainWorker();
        var idle_queue = self.idle_queue.load(.relaxed);

        while (true) {
            const idle_ptr = idle_queue.value.get() & ~@as(usize, ~@as(@TagType(State), 0));
            const idle_state = @intToEnum(State, @truncate(@TagType(State), idle_queue.value.get()));

            if (
                (idle_state == .suspend_notified) or
                (worker_state == .waking and idle_state == .waking_notified)
            ) {
                const new_state: State = switch (idle_state) {
                    .waking_notified => .waking,
                    .suspend_notified => .ready,
                    else => unreachable,
                };

                if (self.idle_queue.tryCompareAndSwap(
                    idle_queue,
                    idle_ptr | @enumToInt(new_state),
                    .relaxed,
                    .relaxed,
                )) |updated| {
                    idle_queue = updated;
                    continue;
                }

                worker.state.store(worker_state, .unordered);
                return .retry;
            }
            
            const idle_worker = @intToPtr(?*Worker, idle_ptr);
            worker.idle_next = idle_worker;
            worker.state.store(if (idle_state == .shutdown) .stopping else .suspended, .unordered);

            const idle_position = if (idle_worker) |w| w.idle_position.load(.unordered) + 1 else 0;
            worker.idle_position.store(idle_position, .unordered);

            if (self.idle_queue.tryCompareAndSwap(
                idle_queue,
                @ptrToInt(worker) | @enumToInt(idle_state),
                .release,
                .relaxed,
            )) |updated| {
                idle_queue = updated;
                continue;
            }

            var active_workers: usize = undefined;
            if (idle_state == .shutdown) {
                active_workers = self.active_workers.fetchSub(1, .release);
                if (active_workers == 1) {
                    const main_worker = self.main_worker orelse @panic("no main worker when shutting down");
                    main_worker.state.store(.joining, .unordered);
                    self.platform.call(.{
                        .resumed = .{
                            .scheduler = self,
                            .worker = main_worker,
                            .intent = .normal,
                        },
                    });
                }
            } else {
                active_workers = self.active_workers.load(.relaxed);
            }

            if (idle_position == 0)
                return .first;
            if (active_workers > 0 and idle_position == active_workers - 1)
                return .last;
            return .normal;
        }
    }

    fn join(self: *Scheduler) void {
        const idle_queue = self.idle_queue.load(.acquire);
        const idle_ptr = idle_queue.value.get() & ~@as(usize, ~@as(@TagType(State), 0));

        var idle_worker = @intToPtr(?*Worker, idle_ptr);
        while (idle_worker) |new_idle_worker| {
            const worker = new_idle_worker;
            idle_worker = worker.idle_next;

            const worker_state = worker.state.load(.unordered);
            if (worker_state != .stopping and worker_state != .joining)
                @panic("worker shutting down with an invalid state");
            worker.state.store(.shutdown, .unordered);

            if (worker_state == .stopping) {
                self.platform.call(.{
                    .resumed = .{
                        .scheduler = self,
                        .worker = worker,
                        .intent = .join,
                    },
                });
            }
        }
    }

    pub fn shutdown(self: *Scheduler) void {
        var idle_queue = self.idle_queue.load(.relaxed);

        while (true) {
            const idle_state = @intToEnum(State, @truncate(@TagType(State), idle_queue.value.get()));
            if (idle_state == .shutdown)
                return;

            if (self.idle_queue.tryCompareAndSwap(
                idle_queue,
                @enumToInt(State.shutdown),
                .acquire,
                .relaxed,
            )) |updated| {
                idle_queue = updated;
                continue;
            }

            var idle_worker = @intToPtr(?*Worker, idle_queue.value.get() & ~@as(usize, ~@as(@TagType(State), 0)));
            while (idle_worker) |new_idle_worker| {
                const worker = new_idle_worker;
                idle_worker = worker.idle_next;

                const worker_state = worker.state.load(.unordered);
                if (worker_state != .suspended)
                    @panic("stopping worker with invalid state");
                worker.state.store(.stopping, .unordered);

                self.platform.call(.{
                    .resumed = .{
                        .scheduler = self,
                        .worker = worker,
                        .intent = .normal,
                    },
                });
            }

            return;
        }
    }

    const IdleQueue = switch (core.arch_type) {
        .i386, .x86_64 => extern struct {
            value: Atomic(usize) align(@alignOf(DoubleWord)),
            aba_tag: Atomic(usize) = Atomic(usize).init(0),

            const DoubleWord = std.meta.Int(.unsigned, std.meta.bitCount(usize) * 2);

            fn get(self: IdleQueue) usize {
                return self.value.get();
            }

            fn load(
                self: *const IdleQueue,
                comptime ordering: Ordering,
            ) IdleQueue {
                return IdleQueue{
                    .value = Atomic(usize).init(self.value.load(ordering)),
                    .aba_tag = Atomic(usize).init(self.aba_tag.load(.relaxed)),
                };
            }

            fn tryCompareAndSwap(
                self: *IdleQueue,
                compare: IdleQueue,
                exchange: usize,
                comptime success: Ordering,
                comptime failure: Ordering,
            ) ?IdleQueue {
                const dword_ptr = @ptrCast(*Atomic(DoubleWord), self);
                const dword_value = dword_ptr.tryCompareAndSwap(
                    @bitCast(DoubleWord, compare),
                    @bitCast(DoubleWord, IdleQueue{
                        .value = Atomic(usize).init(exchange),
                        .aba_tag = Atomic(usize).init(compare.aba_tag.get() +% 1),
                    }),
                    success,
                    failure,
                ) orelse return null;
                return @bitCast(IdleQueue, dword_value);
            }
        },
        else => extern struct {
            value: Atomic(usize),

            fn get(self: IdleQueue) usize {
                return self.value.get();
            }

            fn load(
                self: *const IdleQueue,
                comptime ordering: Ordering,
            ) IdleQueue {
                return IdleQueue{
                    .value = Atomic(usize).init(self.value.load(ordering)),
                };
            }

            fn tryCompareAndSwap(
                self: *IdleQueue,
                compare: IdleQueue,
                exchange: usize,
                comptime success: Ordering,
                comptime failure: Ordering,
            ) ?IdleQueue {
                const value = self.tryCompareAndSwap(
                    compare.value,
                    exchange,
                    success,
                    failure,
                ) orelse return null;
                return IdleQueue{ .value = value };
            }
        },
    };
};

pub const Platform = struct {
    callFn: fn(*Platform, Action) void,

    pub const Action = union(enum) {
        polled: Polled,
        spawned: Spawned,
        resumed: Resumed,

        pub const Polled = struct {
            worker: *Worker,
            batch: *Task.Batch,
            intent: Intent,

            pub const Intent = enum {
                first,
                last,
            };
        };

        pub const Spawned = struct {
            scheduler: *Scheduler,
            succeeded: *bool,
            intent: Intent,

            pub const Intent = enum {
                first,
                last,
                normal,
            };
        };

        pub const Resumed = struct {
            scheduler: *Scheduler,
            worker: *Worker,
            intent: Intent,

            pub const Intent = enum {
                first,
                last,
                normal,
                join,
            };
        };
    };

    pub fn call(self: *Platform, action: Action) void {
        return (self.callFn)(self, action);
    }
};

