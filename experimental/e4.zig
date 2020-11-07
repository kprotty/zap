const std = @import("std");
const core = @import("real_zap").core;

const Mutex = struct {
    srwlock: usize = 0,

    fn tryAcquire(self: *Mutex) bool {
        return TryAcquireSRWLockExclusive(&self.srwlock) != 0;
    }

    fn acquire(self: *Mutex) void {
        AcquireSRWLockExclusive(&self.srwlock);
    }

    fn release(self: *Mutex) void {
        ReleaseSRWLockExclusive(&self.srwlock);
    }

    extern "kernel32" fn TryAcquireSRWLockExclusive(p: *usize) callconv(.Stdcall) u8;
    extern "kernel32" fn AcquireSRWLockExclusive(p: *usize) callconv(.Stdcall) void;
    extern "kernel32" fn ReleaseSRWLockExclusive(p: *usize) callconv(.Stdcall) void;
};

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
        size: usize = 0,

        pub fn from(task: *Task) Batch {
            task.next = null;
            return Batch{
                .head = task,
                .tail = task,
                .size = 1,
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
                self.size += other.size;
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
                self.size += other.size;
            }
        }

        pub fn pop(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            self.size -= 1;
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
        lock: Mutex = Mutex{},
        queue: Batch = Batch{},
        size: Atomic(usize) = Atomic(usize).init(0),

        fn init(self: *UnboundedQueue) void {
            self.* = UnboundedQueue{};
        }

        fn tryAcquire(self: *UnboundedQueue) bool {
            if (self.size.load(.acquire) == 0)
                return false;
            return self.lock.tryAcquire();
        }

        fn release(self: *UnboundedQueue) void {
            self.size.store(self.queue.size, .release);
            self.lock.release();
        }

        fn push(self: *UnboundedQueue, batch: Batch) void {
            if (batch.isEmpty())
                return;

            self.lock.acquire();
            defer self.lock.release();

            self.queue.pushMany(batch);
            self.size.store(self.queue.size, .release);
        }

        fn pop(self: *UnboundedQueue) ?*Task {
            return self.queue.pop();
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
        runq_buffer: [256]Atomic(*Task) = undefined,
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

            var tail = self.runq_tail.get();
            var head = self.runq_head.load(.relaxed);
            while (!batch.isEmpty()) {

                if (tail -% head < self.runq_buffer.len) {
                    while (tail -% head < self.runq_buffer.len) {
                        const task = batch.pop() orelse break;
                        self.runq_buffer[tail % self.runq_buffer.len].store(task, .unordered);
                        tail +%= 1;
                    }

                    self.runq_tail.store(tail, .release);
                    spinLoopHint();
                    head = self.runq_head.load(.relaxed);
                    continue;
                }

                if (self.runq_head.tryCompareAndSwap(
                    head,
                    tail,
                    .relaxed,
                    .relaxed,
                )) |updated| {
                    head = updated;
                    continue;
                }

                var overflowed = Batch{};
                var of = head +% (self.runq_buffer.len / 2);
                while (of != tail) {
                    const task = self.runq_buffer[of % self.runq_buffer.len].get();
                    overflowed.push(task);
                    of +%= 1;
                }

                of = tail +% (self.runq_buffer.len / 2);
                while (tail != of) {
                    const task = self.runq_buffer[head % self.runq_buffer.len].get();
                    self.runq_buffer[tail % self.runq_buffer.len].store(task, .unordered);
                    head +%= 1;
                    tail +%= 1;
                }

                self.runq_tail.store(tail, .release);
                batch.pushFrontMany(overflowed);
                break;
            }

            self.runq_overflow.push(batch);
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

            var tail = self.runq_tail.get();
            var head = self.runq_head.load(.relaxed);
            while (tail -% head > 0) {
                head = self.runq_head.tryCompareAndSwap(
                    head,
                    head +% 1,
                    .relaxed,
                    .relaxed,
                ) orelse return self.runq_buffer[head % self.runq_buffer.len].get();
            }

            return null;
        }

        fn pollUnbounded(self: *Worker, target: *UnboundedQueue) ?*Task {
            if (!target.tryAcquire())
                return null;

            const tail = self.runq_tail.get();
            const head = self.runq_head.load(.relaxed);
            if (tail -% head > self.runq_buffer.len)
                panic("invalid runq size when stealing from scheduler");

            const first_task: ?*Task = target.pop();

            var new_tail = tail;
            while (new_tail -% head < self.runq_buffer.len) {
                const task = target.pop() orelse break;
                self.runq_buffer[new_tail % self.runq_buffer.len].store(task, .unordered);
                new_tail +%= 1;
            }

            target.release();

            if (tail != new_tail)
                self.runq_tail.store(new_tail, .release);
            return first_task;
        }

        fn pollWorker(noalias self: *Worker, noalias target: *Worker) ?*Task {
            const tail = self.runq_tail.get();
            const head = self.runq_head.load(.relaxed);
            if (tail -% head > 0) {
                // panic("stealing from another worker when local queue isnt empty");
                //
                // this seems to randomly happen, reporting size = (self.runq_buffer.len / 2) + 1 ?
                // for now, as a hack, just poll the local queue since it somehow fills up...
                return self.pollSelf();
            }

            var target_head = target.runq_head.load(.relaxed);
            while (true) {
                const target_tail = target.runq_tail.load(.acquire);
                const target_size = target_tail -% target_head;

                var steal = target_size - (target_size / 2);
                if (steal == 0) {
                    break;
                }

                if (steal > target.runq_buffer.len / 2) {
                    spinLoopHint();
                    target_head = target.runq_head.load(.relaxed);
                    continue;
                }

                const first_task = target.runq_buffer[target_head % target.runq_buffer.len].load(.unordered);
                var new_target_head = target_head +% 1;
                var new_tail = tail;
                steal -= 1;

                while (new_target_head -% target_head < steal) {
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

            return null;
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