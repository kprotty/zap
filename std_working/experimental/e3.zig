const std = @import("std");
const core = @import("real_zap").core;

const Thread = std.Thread;
const Atomic = core.sync.atomic.Atomic;
const spinLoopHint = core.sync.atomic.spinLoopHint;

fn panic(comptime fmt: []const u8) noreturn {
    std.debug.panic(fmt, .{});
}

pub const Task = struct {
    next: ?*Task = undefined,
    frame: usize,

    pub fn initAsync(frame: anyframe) Task {
        return Task{ .frame = @ptrToInt(frame) };
    }

    fn ReturnTypeOf(comptime asyncFn: anytype) type {
        return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
    }

    pub const Config = struct {
        threads: ?u8 = null,
    };

    pub fn runAsync(config: Config, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        const Decorator = struct {
            fn call(fn_args: anytype, task: *Task, result: *?ReturnTypeOf(asyncFn)) void {
                suspend task.* = Task.initAsync(@frame());
                const res = @call(.{}, asyncFn, fn_args);
                suspend {
                    result.* = res;
                    Worker.current.?.scheduler.shutdown();
                }
            }
        };

        var task: Task = undefined;
        var result: ?ReturnTypeOf(asyncFn) = null;
        var frame = async Decorator.call(args, &task, &result);

        const num_threads = 
            if (std.builtin.single_threaded) 
                @as(u8, 1)
            else if (config.threads) |threads|
                std.math.max(1, threads)
            else
                @intCast(u8, Thread.cpuCount() catch 1);

        var scheduler: Scheduler = undefined;
        scheduler.init(num_threads);
        defer scheduler.deinit();

        scheduler.run(Batch.from(&task));

        return result orelse error.Deadlocked;
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
                
            const worker = Worker.current.?;
            worker.schedule(self, hints);
        }
    };

    pub fn schedule(self: *Task) void {
        Batch.from(self).schedule(.{});
    }

    pub fn scheduleNext(self: *Task) void {
        Batch.from(self).schedule(.{ .use_next = true });
    }

    pub fn runConcurrentlyAsync() void {
        suspend {
            var task = Task.initAsync(@frame());
            Batch.from(&task).schedule(.{ .use_lifo = true });
        }
    }

    pub fn yieldAsync() void {
        suspend {
            var task = Task.initAsync(@frame());
            task.schedule();
        }
    }

    const UnboundedQueue = struct {
        head: Atomic(*Task),
        tail: Atomic(usize),
        stub: Task,

        const IS_LOCKED: usize = 1;

        fn init(self: *UnboundedQueue) void {
            self.head.set(&self.stub);
            self.tail.set(@ptrToInt(&self.stub));
            self.stub.next = null;
        } 

        fn tryAcquire(self: *UnboundedQueue) bool {
            if (self.head.load(.relaxed) == &self.stub)
                return false;

            if (core.is_x86) {
                return asm volatile(
                    "lock btsw $0, %[ptr]"
                    : [ret] "={@ccc}" (-> u8),
                    : [ptr] "*m" (&self.tail)
                    : "cc", "memory"
                ) == 0;
            }

            var tail = self.tail.load(.relaxed);
            while (true) {
                if (tail & IS_LOCKED != 0)
                    return false;
                tail = self.tail.tryCompareAndSwap(
                    tail,
                    tail | IS_LOCKED,
                    .acquire,
                    .relaxed,
                ) orelse return true;
            }
        }

        fn release(self: *UnboundedQueue) void {
            const unlocked_tail = self.tail.get() & ~IS_LOCKED;
            self.tail.store(unlocked_tail, .release);
        }

        fn push(self: *UnboundedQueue, batch: Batch) void {
            if (batch.isEmpty())
                return;

            batch.tail.next = null;
            const prev = self.head.swap(batch.tail, .acq_rel);
            @ptrCast(*Atomic(?*Task), &prev.next).store(batch.head, .release);
        }

        fn pop(self: *UnboundedQueue) ?*Task {
            var new_tail = @intToPtr(*Task, self.tail.get() & ~IS_LOCKED);
            defer self.tail.set(@ptrToInt(new_tail) | IS_LOCKED);
            
            var tail = new_tail;
            var next = @ptrCast(*Atomic(?*Task), &tail.next).load(.consume);

            if (tail == &self.stub) {
                tail = next orelse return null;
                new_tail = tail;
                next = @ptrCast(*Atomic(?*Task), &tail.next).load(.consume);
            }

            if (next) |next_tail| {
                new_tail = next_tail;
                return tail;
            }

            const head = self.head.load(.relaxed);
            if (head != tail)
                return null;

            self.push(Batch.from(&self.stub));

            if (@ptrCast(*Atomic(?*Task), &tail.next).load(.acquire)) |next_tail| {
                new_tail = next_tail;
                return tail;
            }

            return null;
        }
    };

    pub const Worker = struct {
        scheduler: *Scheduler,
        thread: ?*Thread,
        target: ?*Worker = null,
        idle_next: ?*Worker = null,
        active_next: ?*Worker = null,
        event: std.AutoResetEvent = std.AutoResetEvent{},
        runq_tick: usize,
        runq_next: ?*Task = null,
        runq_lifo: Atomic(?*Task) = Atomic(?*Task).init(null),
        runq_head: Atomic(u32) = Atomic(u32).init(0),
        runq_tail: Atomic(u32) = Atomic(u32).init(0),
        runq_buffer: [256]*Task = undefined,
        runq_overflow: UnboundedQueue,

        fn init(self: *Worker, scheduler: *Scheduler, thread: ?*Thread) void {
            self.* = Worker{
                .scheduler = scheduler,
                .thread = thread,
                .runq_tick = @ptrToInt(self) *% @ptrToInt(scheduler) ^ @ptrToInt(thread),
                .runq_overflow = undefined,
            };
            self.runq_overflow.init();
        }

        fn deinit(self: *Worker) void {
            self.* = undefined;
        }

        threadlocal var current: ?*Worker = null;

        fn run(self: *Worker) void {
            const old_current = current;
            current = self;
            defer current = old_current;

            var is_waking = true;
            var scheduler = self.scheduler;

            var activeq = scheduler.activeq.load(.relaxed);
            while (true) {
                self.active_next = activeq;
                activeq = scheduler.activeq.tryCompareAndSwap(
                    activeq,
                    self,
                    .release,
                    .relaxed,
                ) orelse break;
            }

            while (true) {
                if (self.poll(scheduler)) |task| {
                    if (is_waking)
                        scheduler.resumeWorker(is_waking);
                    is_waking = false;
                    self.runq_tick +%= 1;
                    resume @intToPtr(anyframe, task.frame);
                    continue;
                }

                is_waking = switch (scheduler.suspendWorker(self, is_waking)) {
                    .retry => false,
                    .waking => true,
                    .shutdown => break,
                };
            }
        }

        pub const ScheduleHints = struct {
            use_next: bool = false,
            use_lifo: bool = false,
        };

        pub fn schedule(self: *Worker, tasks: Batch, hints: ScheduleHints) void {
            var batch = tasks;
            if (batch.isEmpty())
                return;

            if (hints.use_next) {
                const old_next = self.runq_next;
                self.runq_next = batch.pop();
                if (old_next) |next|
                    batch.pushFront(next);
                if (batch.isEmpty())
                    return;
            }

            if (hints.use_lifo) {
                if (self.runq_lifo.swap(batch.pop(), .release)) |old_lifo| {
                    batch.pushFront(old_lifo);
                }
            }

            while (!batch.isEmpty()) {
                const head = self.runq_head.load(.acquire);
                const steal = @bitCast([2]u16, head)[0];
                var real = @bitCast([2]u16, head)[1];

                const tail = @truncate(u16, self.runq_tail.get());
                if (tail -% steal < self.runq_buffer.len) {
                    const task = batch.pop() orelse unreachable;
                    self.runq_buffer[tail % self.runq_buffer.len] = task;
                    self.runq_tail.store(tail +% 1, .release);
                    continue;
                }
                
                if (steal != real) {
                    self.runq_overflow.push(batch);
                    break;
                }

                var n = @as(u16, self.runq_buffer.len / 2);
                if (tail -% real != self.runq_buffer.len)
                    std.debug.panic("queue is not full; tail={} head={} size={}\n", .{tail, real, tail -% real});

                if (self.runq_head.tryCompareAndSwap(
                    head,
                    @bitCast(u32, [_]u16{ real +% n, real +% n }),
                    .release,
                    .relaxed,
                )) |_| {
                    spinLoopHint();
                    continue;
                }

                var overflowed = Batch{};
                while (n > 0) : (n -= 1) {
                    const task = self.runq_buffer[real % self.runq_buffer.len];
                    overflowed.push(task);
                    real +%= 1;
                }
                
                batch.pushFrontMany(overflowed);
                self.runq_overflow.push(batch);
                break;
            }

            self.scheduler.resumeWorker(false);
        }

        fn poll(self: *Worker, scheduler: *Scheduler) ?*Task {
            if (self.runq_tick % 61 == 0) {
                if (self.pollUnbounded(&scheduler.runq)) |task| {
                    return task;
                }
            }

            if (self.runq_tick % 31 == 0) {
                if (self.pollUnbounded(&self.runq_overflow)) |task| {
                    return task;
                }
            }

            if (self.pollSelf()) |task| {
                return task;
            }

            if (self.pollUnbounded(&self.runq_overflow)) |task| {
                return task;
            }

            var workers = blk: {
                const counter_value = scheduler.counter.load(.relaxed);
                const counter = Scheduler.Counter.unpack(counter_value);
                break :blk counter.spawned;
            };

            while (workers > 0) : (workers -= 1) {
                const target = self.target orelse blk: {
                    const target = scheduler.activeq.load(.consume);
                    self.target = target;
                    break :blk (target orelse panic("no active workers when stealing"));
                };

                self.target = target.active_next;
                if (target == self)
                    continue;

                if (self.pollWorker(target)) |task| {
                    return task;
                } else if (self.pollUnbounded(&target.runq_overflow)) |task| {
                    return task;
                } else if (target.runq_lifo.load(.relaxed) != null) {
                    if (target.runq_lifo.swap(null, .acquire)) |task| {
                        return task;
                    }
                }
            }

            if (self.pollUnbounded(&scheduler.runq)) |task| {
                return task;
            }

            return null;
        }

        fn pollSelf(noalias self: *Worker) ?*Task {
            if (self.runq_next) |next| {
                const task = next;
                self.runq_next = null;
                return task;
            }

            if (self.runq_lifo.load(.relaxed) != null) {
                if (self.runq_lifo.swap(null, .relaxed)) |task| {
                    return task;
                }
            }

            var head = self.runq_head.load(.acquire);
            while (true) {
                const steal = @bitCast([2]u16, head)[0];
                const real = @bitCast([2]u16, head)[1];

                const tail = @truncate(u16, self.runq_tail.get());
                if (tail == real)
                    break;

                const new_real = real +% 1;
                var new_steal = new_real;
                if (steal != real) {
                    if (steal == new_real)
                        std.debug.panic("assert failed: steal={} != new_real={} (real={}) \n", .{steal, real, new_real});
                    new_steal = steal;
                }

                head = self.runq_head.tryCompareAndSwap(
                    head,
                    @bitCast(u32, [2]u16{ new_steal, new_real }),
                    .acq_rel,
                    .acquire,
                ) orelse return self.runq_buffer[real % self.runq_buffer.len];
            }

            return null;
        }

        fn pollUnbounded(self: *Worker, target: *UnboundedQueue) ?*Task {
            if (!target.tryAcquire())
                return null;

            const task = target.pop();
            target.release();

            return task;
        }

        fn pollWorker(noalias self: *Worker, noalias target: *Worker) ?*Task {
            const tail = @truncate(u16, self.runq_tail.get());
            const steal = @bitCast([2]u16, self.runq_head.load(.acquire))[0];
            if (tail -% steal > @as(u16, self.runq_buffer.len / 2))
                return null;

            var n = target.stealInto(self, tail);
            if (n == 0)
                return null;

            n -= 1;
            const task = self.runq_buffer[(tail +% n) % self.runq_buffer.len];
            if (n != 0)
                self.runq_tail.store(tail +% n, .release);
            return task;
        }

        fn stealInto(noalias self: *Worker, noalias dst: *Worker, dst_tail: u16) u16 {
            var head = self.runq_head.load(.acquire);

            const n = blk: {
                while (true) {
                    const steal = @bitCast([2]u16, head)[0];
                    const real = @bitCast([2]u16, head)[1];

                    const tail = @truncate(u16, self.runq_tail.load(.acquire));
                    if (steal != real)
                        return 0;

                    var n = tail -% real;
                    n = n - (n / 2);
                    if (n == 0)
                        return 0;

                    const new_real = real +% n;
                    if (steal == new_real)
                        std.debug.panic("assert fail: steal={} new_real={} (real={})\n", .{steal, new_real, real});

                    const new_head = @bitCast(u32, [2]u16{ steal, new_real });
                    head = self.runq_head.tryCompareAndSwap(
                        head,
                        new_head,
                        .acq_rel,
                        .acquire,
                    ) orelse {
                        head = new_head;
                        break :blk n;
                    };
                }
            };

            const first = @bitCast([2]u16, head)[0];
            var i: u16 = 0;
            while (i < n) : (i += 1) {
                const task = self.runq_buffer[(first +% i) % self.runq_buffer.len];
                dst.runq_buffer[(dst_tail +% i) % dst.runq_buffer.len] = task;
            }

            while (true) {
                const h = @bitCast([2]u16, head)[1];
                const new_head = @bitCast(u32, [2]u16{ h, h });

                head = self.runq_head.tryCompareAndSwap(
                    head,
                    new_head,
                    .acq_rel,
                    .acquire,
                ) orelse return n;

                const steal = @bitCast([2]u16, head)[0];
                const real = @bitCast([2]u16, head)[1];
                if (steal == real)
                    std.debug.panic("assert failed: steal={} != real={}\n", .{steal, real});
            }
        }
    };

    pub const Scheduler = struct {
        max_workers: u16,
        main_worker: ?*Worker = null,
        runq: UnboundedQueue = undefined,
        counter: Atomic(u32) = Atomic(u32).init(0),
        idleq: Atomic(usize) = Atomic(usize).init(0),
        activeq: Atomic(?*Worker) = Atomic(?*Worker).init(null),
        
        const Counter = struct {
            idle: u16 = 0,
            spawned: u16 = 0,
            state: State = .pending,

            const State = enum(u4) {
                pending = 0,
                waking,
                waking_notified,
                suspend_notified,
                shutdown,
            };

            fn unpack(value: u32) Counter {
                return Counter{
                    .idle = @truncate(u14, value >> (14 + 4)),
                    .spawned = @truncate(u14, value >> 4),
                    .state = @intToEnum(State, @truncate(u4, value)),
                };
            }

            fn pack(self: Counter) u32 {
                return (
                    (@as(u32, @intCast(u14, self.idle)) << (14 + 4)) |
                    (@as(u32, @intCast(u14, self.spawned)) << 4) |
                    @as(u32, @enumToInt(self.state))
                );
            }
        };

        pub fn init(self: *Scheduler, num_workers: u16) void {
            const max_workers = std.math.min(num_workers, std.math.maxInt(u14));
            self.* = Scheduler{ .max_workers = max_workers };
            self.runq.init();
        }

        pub fn deinit(self: *Scheduler) void {
            self.* = undefined;
        }

        pub fn run(self: *Scheduler, batch: Batch) void {
            if (batch.isEmpty())
                return;

            self.runq.push(batch);
            self.resumeWorker(false);
        }

        fn resumeWorker(self: *Scheduler, is_caller_waking: bool) void {
            var attempts_left: u8 = 5;
            var is_waking = is_caller_waking;
            var max_workers = self.max_workers;
            var counter = Counter.unpack(self.counter.load(.relaxed));

            while (true) {
                if (counter.state == .shutdown)
                    return;

                if ((counter.idle > 0 or counter.spawned < max_workers) and (
                    (is_waking and attempts_left > 0) or
                    (!is_waking and counter.state == .pending)
                )) {
                    var new_counter = counter;
                    new_counter.state = .waking;
                    if (counter.idle > 0) {
                        new_counter.idle -= 1;
                    } else {
                        new_counter.spawned += 1;
                    }

                    if (self.counter.tryCompareAndSwap(
                        counter.pack(),
                        new_counter.pack(),
                        .relaxed,
                        .relaxed,
                    )) |updated| {
                        counter = Counter.unpack(updated);
                        continue;
                    }

                    if (counter.idle > 0) {
                        return self.notify();
                    } else if (self.spawn(counter.spawned)) {
                        return;
                    }

                    spinLoopHint();
                    is_waking = true;
                    attempts_left -= 1;
                    counter = Counter.unpack(self.counter.load(.relaxed));
                    continue;
                }

                var new_counter = counter;
                new_counter.state = blk: {
                    if (is_waking) {
                        if (counter.idle > 0 or counter.spawned < max_workers)
                            break :blk Counter.State.pending;
                        break :blk Counter.State.suspend_notified;
                    } else if (counter.state == .waking) {
                        break :blk Counter.State.waking_notified;
                    } else if (counter.state == .pending) {
                        break :blk Counter.State.suspend_notified;
                    } else {
                        return;
                    }
                };

                counter = Counter.unpack(self.counter.tryCompareAndSwap(
                    counter.pack(),
                    new_counter.pack(),
                    .relaxed,
                    .relaxed,
                ) orelse return);
            }
        }

        const Suspended = enum {
            retry,
            waking,
            shutdown,
        };

        fn suspendWorker(self: *Scheduler, worker: *Worker, is_waking: bool) Suspended {
            var max_workers = self.max_workers;
            var counter = Counter.unpack(self.counter.load(.relaxed));

            while (true) {
                const notified = switch (counter.state) {
                    .waking_notified => is_waking,
                    .suspend_notified => true,
                    else => false,
                };

                var new_counter = counter;
                if (counter.state == .shutdown) {
                    new_counter.spawned -= 1;
                } else if (notified) {
                    new_counter.state = if (is_waking) .waking else .pending;
                } else {
                    if (is_waking) 
                        new_counter.state = if (counter.idle > 0 or counter.spawned < max_workers) .pending else .suspend_notified;
                    new_counter.idle += 1; 
                }

                if (self.counter.tryCompareAndSwap(
                    counter.pack(),
                    new_counter.pack(),
                    .relaxed,
                    .relaxed,
                )) |updated| {
                    counter = Counter.unpack(updated);
                    continue;
                }

                if (notified and is_waking)
                    return .waking;
                if (notified)
                    return .retry;
                if (counter.state != .shutdown) {
                    self.wait(worker);
                    return .waking;
                }

                if (new_counter.spawned == 0) {
                    const main_worker = self.main_worker orelse panic("workers shutdown without a main worker");
                    main_worker.event.set();
                }

                worker.event.wait();
                if (worker.thread != null)
                    return .shutdown;

                var workers = self.activeq.load(.acquire);
                while (workers) |active_worker| {
                    const idle_worker = active_worker;
                    workers = idle_worker.active_next;

                    const thread = idle_worker.thread orelse continue;
                    idle_worker.event.set();
                    thread.wait();
                }

                return .shutdown;
            }
        }

        fn shutdown(self: *Scheduler) void {
            var counter = Counter.unpack(self.counter.load(.relaxed));

            while (true) {
                if (counter.state == .shutdown)
                    return;
                
                var new_counter = counter;
                new_counter.idle = 0;
                new_counter.state = .shutdown;
                counter = Counter.unpack(self.counter.tryCompareAndSwap(
                    counter.pack(),
                    new_counter.pack(),
                    .relaxed,
                    .relaxed,
                ) orelse return self.notifyAll());
            }
        }

        fn spawn(self: *Scheduler, spawned: u16) bool {
            const Spawner = struct {
                scheduler: *Scheduler,
                thread: ?*Thread = null,
                spawn_event: std.AutoResetEvent = std.AutoResetEvent{},
                thread_event: std.AutoResetEvent = std.AutoResetEvent{},
            };

            const Wrapper = struct {
                fn entry(spawner: *Spawner) void {
                    const scheduler = spawner.scheduler;
                    spawner.thread_event.wait();
                    const thread = spawner.thread;
                    spawner.spawn_event.set();

                    var worker: Worker = undefined;
                    worker.init(scheduler, thread);
                    defer worker.deinit();

                    if (thread == null)
                        scheduler.main_worker = &worker;

                    worker.run();
                }
            };

            var spawner = Spawner{ .scheduler = self };
            
            if (std.builtin.single_threaded or spawned == 0) {
                spawner.thread_event.set();
                Wrapper.entry(&spawner);
                return true;
            }

            spawner.thread = Thread.spawn(&spawner, Wrapper.entry) catch return false;
            spawner.thread_event.set();
            spawner.spawn_event.wait();
            return true;
        }

        const IDLE_EMPTY: usize = 0;
        const IDLE_NOTIFIED: usize = 1;
        const IDLE_SHUTDOWN: usize = 2;

        fn wait(self: *Scheduler, worker: *Worker) void {
            @setCold(true);

            var idleq = self.idleq.load(.relaxed);
            while (true) {
                if (idleq == IDLE_SHUTDOWN)
                    return;

                const new_idleq = blk: {
                    if (idleq == IDLE_NOTIFIED) 
                        break :blk IDLE_EMPTY;
                    worker.idle_next = @intToPtr(?*Worker, idleq);
                    break :blk @ptrToInt(worker);
                };

                idleq = self.idleq.tryCompareAndSwap(
                    idleq,
                    new_idleq,
                    .release,
                    .relaxed,
                ) orelse {
                    if (idleq != IDLE_NOTIFIED)
                        worker.event.wait();
                    return;
                };
            }
        }

        fn notify(self: *Scheduler) void {
            @setCold(true);

            var idleq = self.idleq.load(.consume);
            while (true) {
                if (idleq == IDLE_SHUTDOWN)
                    return;
                if (idleq == IDLE_NOTIFIED)
                    return;

                const idle_worker = @intToPtr(?*Worker, idleq);
                const new_idleq = blk: {
                    const worker = idle_worker orelse break :blk IDLE_NOTIFIED;
                    break :blk @ptrToInt(worker.idle_next);
                };

                idleq = self.idleq.tryCompareAndSwap(
                    idleq,
                    new_idleq,
                    .consume,
                    .consume,
                ) orelse {
                    if (idle_worker) |worker|
                        worker.event.set();
                    return;
                };
            }
        }

        fn notifyAll(self: *Scheduler) void {
            @setCold(true);

            var idleq = self.idleq.swap(IDLE_SHUTDOWN, .consume);
            if (idleq == IDLE_SHUTDOWN)
                panic("scheduler idle queue was shutdown twice");
            if (idleq == IDLE_NOTIFIED)
                return;

            while (@intToPtr(?*Worker, idleq)) |idle_worker| {
                idleq = @ptrToInt(idle_worker.idle_next);
                idle_worker.event.set();
            }
        }
    };
};

pub const AsyncFutex = struct {
    task: *Task = undefined,

    pub fn wait(self: *AsyncFutex, _deadline: anytype, condition: anytype) bool {
        var task = Task.initAsync(@frame());

        suspend {
            self.task = &task;
            if (condition.isMet())
                task.scheduleNext();
        }

        return true;
    }

    pub fn wake(self: *AsyncFutex) void {
        Task.Batch.from(self.task).schedule(.{ .use_lifo = true });
    }
};

pub const Lock = extern struct {
    lock: core.sync.Lock = core.sync.Lock{},

    pub fn tryAcquire(self: *Lock) void {
        return self.lock.tryAcquire();
    }

    pub fn acquire(self: *Lock) void {
        self.lock.acquire(@import("real_zap").platform.Futex);
    }

    pub fn acquireAsync(self: *Lock) void {
        self.lock.acquire(AsyncFutex);
    }

    pub fn release(self: *Lock) void {
        self.lock.release();
    }
};