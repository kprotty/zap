const std = @import("std");
const core = @import("real_zap").core;

const Atomic = core.sync.atomic.Atomic;
const spinLoopHint = core.sync.atomic.spinLoopHint;

pub const Task = struct {
    next: ?*Task = undefined,
    frame: anyframe,

    pub fn initAsync(frame: anyframe) Task {
        return Task{ .frame = frame };
    }

    fn ReturnTypeOf(comptime asyncFn: anytype) type {
        return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
    }

    pub const Config = struct {
        threads: ?u16 = null,
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
                @as(u16, 1)
            else if (config.threads) |threads|
                std.math.max(1, threads)
            else
                @intCast(u16, Thread.cpuCount() catch 1);

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

        pub fn schedule(self: Batch) void {
            if (self.isEmpty())
                return;
                
            const worker = Worker.current.?;
            if (worker.run_queue.push(self)) |overflowed|
                worker.overflow_queue.push(overflowed);

            const scheduler = worker.scheduler;
            scheduler.resumeWorker(false);
        }
    };

    pub const runConcurrentlyAsync = yieldAsync;
    pub fn yieldAsync() void {
        suspend {
            var task = Task.initAsync(@frame());
            Batch.from(&task).schedule();
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

    const BoundedQueue = struct {
        head: Atomic(usize) = Atomic(usize).init(0),
        tail: Atomic(usize) = Atomic(usize).init(0),
        buffer: [256]Atomic(*Task) = undefined,

        fn push(self: *BoundedQueue, tasks: Batch) ?Batch {
            var batch = tasks;
            if (batch.isEmpty())
                return null;

            var tail = self.tail.get();
            var head = self.head.load(.relaxed);

            while (true) {
                var remaining = self.buffer.len - (tail -% head);
                if (remaining > 0) {
                    while (remaining > 0) : (remaining -= 1) {
                        const task = batch.pop() orelse break;
                        self.buffer[tail % self.buffer.len].store(task, .unordered);
                        tail +%= 1;
                    }

                    self.tail.store(tail, .release);
                    if (batch.isEmpty())
                        return null;

                    head = self.head.load(.relaxed);
                    continue;
                }

                const new_head = head +% (self.buffer.len / 2);
                if (self.head.tryCompareAndSwap(
                    head,
                    new_head,
                    .relaxed,
                    .relaxed,
                )) |updated| {
                    head = updated;
                    continue;
                }

                var overflowed = Batch{};
                while (head != new_head) : (head +%= 1) {
                    const task = self.buffer[head % self.buffer.len].get();
                    overflowed.push(task);
                }

                batch.pushFrontMany(overflowed);
                return batch;
            }
        }

        fn pop(self: *BoundedQueue) ?*Task {
            var tail = self.tail.get();
            var head = self.head.load(.relaxed);

            while (true) {
                if (tail == head)
                    return null;
                head = self.head.tryCompareAndSwap(
                    head,
                    head +% 1,
                    .relaxed,
                    .relaxed,
                ) orelse return self.buffer[head % self.buffer.len].get();
            }
        }

        fn tryStealUnbounded(
            noalias self: *BoundedQueue,
            noalias target: *UnboundedQueue,
            noalias injected: *bool,
        ) ?*Task {
            if (!target.tryAcquire())
                return null;

            const tail = self.tail.get();
            const head = self.head.load(.relaxed);

            var first_task = target.pop();
            var new_tail = tail;

            var remaining = self.buffer.len - (tail -% head);
            while (remaining > 0) : (remaining -= 1) {
                const task = target.pop() orelse break;
                self.buffer[new_tail % self.buffer.len].store(task, .unordered);
                new_tail +%= 1;
            }

            target.release();

            if (new_tail != tail) {
                injected.* = true;
                self.tail.store(new_tail, .release);
            }

            return first_task;
        }

        fn tryStealBounded(
            noalias self: *BoundedQueue,
            noalias target: *BoundedQueue,
            noalias injected: *bool,
        ) ?*Task {
            var tail = self.tail.get();
            var target_head = target.head.load(.relaxed);

            while (true) {
                const target_tail = target.tail.load(.acquire);
                const target_size = target_tail -% target_head;

                var steal = target_size - (target_size / 2);
                if (steal > target.buffer.len / 2) {
                    spinLoopHint();
                    target_head = target.head.load(.relaxed);
                    continue;
                } else if (steal == 0) {
                    return null;
                }

                const first_task = target.buffer[target_head % target.buffer.len].load(.unordered);
                var new_target_head = target_head +% 1;
                var new_tail = tail;
                steal -= 1;

                while (steal > 0) : (steal -= 1) {
                    const task = target.buffer[new_target_head % target.buffer.len].load(.unordered);
                    new_target_head +%= 1;
                    self.buffer[new_tail % self.buffer.len].store(task, .unordered);
                    new_tail +%= 1;
                }

                if (target.head.tryCompareAndSwap(
                    target_head,
                    new_target_head,
                    .relaxed,
                    .relaxed,
                )) |updated| {
                    target_head = updated;
                    continue;
                }

                if (new_tail != tail) {
                    injected.* = true;
                    self.tail.store(new_tail, .release);
                }

                return first_task;
            }
        }
    };

    const Worker = struct {
        thread: ?*Thread = undefined,
        shutdown_event: std.AutoResetEvent = std.AutoResetEvent{},
        scheduler: *Scheduler,
        state: State = .waking,
        target: ?*Worker = null,
        next: ?*Worker = undefined,
        run_queue: BoundedQueue = BoundedQueue{},
        overflow_queue: UnboundedQueue = undefined,

        const State = enum {
            waking,
            running,
            suspended,
            stopping,
            shutdown,
        };

        const Spawner = struct {
            scheduler: *Scheduler,
            thread: ?*Thread = null,
            thread_event: std.AutoResetEvent = std.AutoResetEvent{},
            spawn_event: std.AutoResetEvent = std.AutoResetEvent{},
        };

        fn spawn(scheduler: *Scheduler, use_caller_thread: bool) bool {
            var spawner = Spawner{ .scheduler = scheduler };

            if (std.builtin.single_threaded or use_caller_thread) {
                spawner.thread_event.set();
                Worker.run(&spawner);
                return true;
            }

            spawner.thread = Thread.spawn(&spawner, Worker.run) catch return false;
            spawner.thread_event.set();
            spawner.spawn_event.wait();
            return true;
        }

        threadlocal var current: ?*Worker = null;

        fn run(spawner: *Spawner) void {
            const scheduler = spawner.scheduler;
            spawner.thread_event.wait();

            const thread = spawner.thread;
            spawner.spawn_event.set();

            var self = Worker{.scheduler = scheduler };
            self.overflow_queue.init();
            self.thread = thread;

            if (self.thread == null)
                scheduler.main_worker = &self;

            var worker_queue = scheduler.worker_queue.load(.relaxed);
            while (true) {
                self.next = worker_queue;
                worker_queue = scheduler.worker_queue.tryCompareAndSwap(
                    worker_queue,
                    &self,
                    .release,
                    .relaxed,
                ) orelse break;
            }

            const old_current = Worker.current;
            Worker.current = &self;
            defer Worker.current = old_current;

            while (true) {
                const should_poll = switch (self.state) {
                    .running, .waking => true,
                    .suspended => unreachable, // worker running when suspended
                    .stopping => false,
                    .shutdown => break,
                };

                if (should_poll) {
                    var injected = false;
                    if (self.poll(scheduler, &injected)) |task| {
                        if (injected or self.state == .waking)
                            scheduler.resumeWorker(self.state == .waking);
                        
                        self.state = .running;
                        resume task.frame;
                        continue;
                    }
                }

                scheduler.suspendWorker(&self);
            }
        }

        fn poll(self: *Worker, scheduler: *Scheduler, injected: *bool) ?*Task {
            if (self.run_queue.pop()) |task|
                return task;

            if (self.run_queue.tryStealUnbounded(&self.overflow_queue, injected)) |task|
                return task;

            var active_workers = scheduler.idle_queue.load(.relaxed) >> 18;
            while (active_workers > 0) : (active_workers -= 1) {
                const target = self.target orelse blk: {
                    const target = scheduler.worker_queue.load(.consume);
                    self.target = target;
                    break :blk target orelse unreachable;
                };

                self.target = target.next;
                if (target == self)
                    continue;

                if (self.run_queue.tryStealBounded(&target.run_queue, injected)) |task|
                    return task;
                if (self.run_queue.tryStealUnbounded(&target.overflow_queue, injected)) |task|
                    return task;
            }

            if (self.run_queue.tryStealUnbounded(&scheduler.run_queue, injected)) |task|
                return task;

            return null;
        }
    };

    const Scheduler = struct {
        max_workers: u16 = undefined,
        main_worker: ?*Worker = null,
        run_queue: UnboundedQueue = undefined,
        idle_queue: Atomic(u32) = Atomic(u32).init(0),
        worker_queue: Atomic(?*Worker) = Atomic(?*Worker).init(null),
        idle_semaphore: Semaphore = undefined,

        fn init(self: *Scheduler, max_workers: u16) void {
            self.* = Scheduler{};
            self.run_queue.init();
            self.idle_semaphore.init();
            self.max_workers = max_workers;
        }

        fn deinit(self: *Scheduler) void {
            self.idle_semaphore.deinit();
            self.* = undefined;
        }

        fn run(self: *Scheduler, batch: Batch) void {
            self.run_queue.push(batch);
            self.resumeWorker(false);
        }

        const IdleQueue = struct {
            state: State = .pending,
            spawned: u16 = 0,
            suspended: u16 = 0,

            const State = enum(u4) {
                pending = 0,
                waking,
                waking_notified,
                suspend_notified,
                shutdown,
            };
            
            fn unpack(value: u32) IdleQueue {
                var self: IdleQueue = undefined;
                self.state = @intToEnum(State, @truncate(u4, value));
                self.spawned = @truncate(u14, value >> 4);
                self.suspended = @truncate(u14, value >> (4 + 14));
                return self;
            }

            fn pack(self: IdleQueue) u32 {
                var value: u32 = 0;
                value |= @as(u32, @enumToInt(self.state));
                value |= @as(u32, @intCast(u14, self.spawned)) << 4;
                value |= @as(u32, @intCast(u14, self.suspended)) << (4 + 14);
                return value;
            }
        };

        fn resumeWorker(self: *Scheduler, is_caller_waking: bool) void {
            var wake_attempts: u8 = 5;
            var is_waking = is_caller_waking;
            const max_workers = self.max_workers;
            var idle_queue = self.idle_queue.load(.relaxed);

            while (true) {
                const iq = IdleQueue.unpack(idle_queue);
                if (iq.state == .shutdown)
                    return;

                if ((iq.suspended > 0 or iq.spawned < max_workers) and (
                    (is_waking and wake_attempts > 0) or
                    (!is_waking and iq.state == .pending)
                )) {
                    var new_iq = iq;
                    new_iq.state = .waking;
                    const resumed = switch (iq.suspended) {
                        0 => blk: {
                            new_iq.spawned += 1;
                            break :blk false;
                        },
                        else => blk: {
                            new_iq.suspended -= 1;
                            break :blk true;
                        },
                    };

                    if (self.idle_queue.tryCompareAndSwap(
                        idle_queue,
                        new_iq.pack(),
                        .relaxed,
                        .relaxed,
                    )) |updated| {
                        idle_queue = updated;
                        continue;
                    }

                    if (resumed) {
                        return self.idle_semaphore.post(1);
                    } else if (Worker.spawn(self, iq.spawned == 0)) {
                        return;
                    }

                    wake_attempts -= 1;
                    is_waking = true;
                    spinLoopHint();

                    var spawn_iq = IdleQueue.unpack(0);
                    spawn_iq.spawned = 1;
                    idle_queue = self.idle_queue.fetchSub(spawn_iq.pack(), .relaxed);
                    continue;
                }

                var new_iq = iq;
                new_iq.state = blk: {
                    const State = IdleQueue.State;
                    if (is_waking) {
                        if (iq.suspended == 0)
                            break :blk State.suspend_notified;
                        break :blk State.pending;
                    }
                    if (iq.state == .waking)
                        break :blk State.waking_notified;
                    if (iq.state == .pending)
                        break :blk State.suspend_notified;
                    return;
                };

                idle_queue = self.idle_queue.tryCompareAndSwap(
                    idle_queue,
                    new_iq.pack(),
                    .relaxed,
                    .relaxed,
                ) orelse return;
            }
        }

        fn suspendWorker(self: *Scheduler, worker: *Worker) void {
            const worker_state = worker.state;
            var idle_queue = self.idle_queue.load(.relaxed);

            while (true) {
                const iq = IdleQueue.unpack(idle_queue);
                if (iq.state == .shutdown)
                    break;

                const notified = (
                    (iq.state == .suspend_notified) or
                    (worker_state == .waking and iq.state == .waking_notified)
                );

                var new_iq = iq;
                if (notified) {
                    new_iq.state = if (worker_state == .waking) .waking else .pending;
                } else {
                    new_iq.suspended += 1;
                    if (worker_state == .waking)
                        new_iq.state = .pending;
                }

                worker.state = .suspended;
                if (self.idle_queue.tryCompareAndSwap(
                    idle_queue,
                    new_iq.pack(),
                    .relaxed,
                    .relaxed,
                )) |updated| {
                    idle_queue = updated;
                    continue;
                }

                if (notified) {
                    worker.state = worker_state;
                    return;
                }

                self.idle_semaphore.wait();
                idle_queue = self.idle_queue.load(.relaxed);
                worker.state = switch (IdleQueue.unpack(idle_queue).state) {
                    .waking, .waking_notified => .waking,
                    .shutdown => .stopping,
                    else => unreachable,
                };

                return;
            }

            var spawn_iq = IdleQueue.unpack(0);
            spawn_iq.spawned += 1;
            worker.state = .stopping;
            idle_queue = self.idle_queue.fetchSub(spawn_iq.pack(), .release);
            if (IdleQueue.unpack(idle_queue).spawned == 1) {
                const main_worker = self.main_worker orelse unreachable;
                main_worker.shutdown_event.set();
            }

            worker.shutdown_event.wait();
            if (worker.thread != null)
                return;

            idle_queue = self.idle_queue.load(.acquire);
            if (IdleQueue.unpack(idle_queue).spawned != 0)
                unreachable;

            var workers = self.worker_queue.load(.consume);
            while (workers) |idle_worker| {
                const shutdown_worker = idle_worker;
                workers = shutdown_worker.next;

                if (shutdown_worker.state != .stopping)
                    unreachable;
                shutdown_worker.state = .shutdown;

                const shutdown_thread = shutdown_worker.thread;
                shutdown_worker.shutdown_event.set();

                if (shutdown_thread) |thread|
                    thread.wait();
            }
        }

        fn shutdown(self: *Scheduler) void {
            var idle_queue = self.idle_queue.load(.relaxed);

            while (true) {
                const iq = IdleQueue.unpack(idle_queue);
                if (iq.state == .shutdown)
                    return;

                var new_iq = iq;
                new_iq.state = .shutdown;
                new_iq.suspended = 0;

                idle_queue = self.idle_queue.tryCompareAndSwap(
                    idle_queue,
                    new_iq.pack(),
                    .relaxed,
                    .relaxed,
                ) orelse return self.idle_semaphore.post(iq.suspended);
            }
        }
    };
};

const system = std.os.system;
const is_linux = std.builtin.os.tag == .linux;
const is_windows = std.builtin.os.tag == .windows;
const is_darwin = std.Target.current.isDarwin();
const is_freebsd = is_darwin or std.builtin.os.tag == .freebsd or .tag == .kfreebsd;
const is_bsd = is_freebsd or std.builtin.os.tag == .openbsd or .tag == .netbsd or .tag == .dragonfly;
const is_posix = is_linux or is_bsd or std.builtin.os.tag == .minix or .tag == .solaris or .tag == .fuchsia;

const Thread = std.Thread;

const Semaphore = 
    if (is_windows) 
        WindowsSemaphore
    else if (std.builtin.link_libc and is_posix)
        PosixSemaphore
    else if (is_linux)
        LinuxSemaphore
    else
        SpinSemaphore;

const SpinSemaphore = struct {
    counter: Atomic(u32),

    fn init(self: *@This()) void {
        self.counter.set(0);
    }

    fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    fn wait(self: *@This()) void {
        return self.waitUsing(struct {
            fn yield(_: anytype) void {
                spinLoopHint();
            }
        });
    }

    fn waitUsing(self: *@This(), comptime yielder: anytype) void {
        var counter = self.counter.load(.relaxed);
        while (true) {
            if (counter > 0) {
                counter = self.counter.tryCompareAndSwap(
                    counter,
                    counter - 1,
                    .acquire,
                    .relaxed,
                ) orelse return;
            } else {
                yielder.yield(self);
                counter = self.counter.load(.relaxed);
            }
        }
    }

    fn post(self: *@This(), amount: u16) void {
        _ = self.counter.fetchAdd(amount, .release);
    }
};

const WindowsSemaphore = struct {
    key: u32,

    fn init(self: *@This()) void {}
    fn deinit(self: *@This()) void {}

    fn wait(self: *@This()) void {
        const key = @ptrCast(*align(4) const c_void, &self.key);
        const status = NtWaitForKeyedEvent(null, key, system.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    fn post(self: *@This(), amount: u16) void {
        var waiting = amount;
        const key = @ptrCast(*align(4) const c_void, &self.key);

        while (waiting > 0) : (waiting -= 1) {
            const status = NtReleaseKeyedEvent(null, key, system.FALSE, null);
            std.debug.assert(status == .SUCCESS);
        }
    }

    extern "NtDll" fn NtWaitForKeyedEvent(
        handle: ?system.HANDLE,
        key: ?*align(4) const c_void,
        alertable: system.BOOLEAN,
        timeout: ?*const system.LARGE_INTEGER,
    ) callconv(.Stdcall) system.NTSTATUS;

    extern "NtDll" fn NtReleaseKeyedEvent(
        handle: ?system.HANDLE,
        key: ?*align(4) const c_void,
        alertable: system.BOOLEAN,
        timeout: ?*const system.LARGE_INTEGER,
    ) callconv(.Stdcall) system.NTSTATUS;
};

const LinuxSemaphore = struct {
    spin: SpinSemaphore,

    fn init(self: *@This()) void {
        self.spin.init();
    }

    fn deinit(self: *@This()) void {
        self.spin.deinit();
    }

    fn wait(self: *@This()) void {
        return self.spin.waitUsing(struct {
            fn yield(spin: *SpinSemaphore) void {
                const rc = system.futex_wait(
                    @ptrCast(*const i32, spin),
                    system.FUTEX_PRIVATE_FLAG | system.FUTEX_WAIT,
                    @as(i32, 0),
                    null,
                );

                switch (system.getErrno(rc)) {
                    0, system.EINTR, system.EAGAIN => {},
                    else => unreachable,
                }
            }
        });
    }

    fn post(self: *@This(), amount: u16) void {
        self.spin.post(amount);

        const ptr = @ptrCast(*const i32, &self.counter);
        const op = system.FUTEX_PRIVATE_FLAG | system.FUTEX_WAKE;
        const rc = system.futex_wake(ptr, op, amount);
        std.debug.assert(rc >= 0 and rc <= amount);
    }
};

const PosixSemaphore = struct {
    spin: SpinSemaphore,
    use_spin: bool,
    cond: pthread_cond_t,
    mutex: pthread_mutex_t,

    fn init(self: *@This()) void {
        self.use_spin = true;

        if (pthread_cond_init(&self.cond, null) == 0) {
            if (pthread_mutex_init(&self.mutex, null) == 0) {
                self.use_spin = false;
            } else {
                std.debug.assert(pthread_cond_destroy(&self.cond) == 0);
            }
        }
    }

    fn deinit(self: *@This()) void {
        if (self.use_spin)
            return;

        std.debug.assert(pthread_cond_destroy(&self.cond) == 0);
        std.debug.assert(pthread_mutex_destroy(&self.mutex) == 0);
    }

    fn wait(self: *@This()) void {
        if (self.use_spin) {
            return self.spin.waitUsing(struct {
                fn yield(_: anytype) void {
                    _ = sched_yield();
                }
            });
        }

        std.debug.assert(pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(pthread_mutex_unlock(&self.mutex) == 0);

        while (true) {
            const counter = self.spin.counter.get();
            if (counter > 0) {
                return self.spin.counter.set(counter - 1);
            } else {
                std.debug.assert(pthread_cond_wait(&self.cond, &self.mutex) == 0);
            }   
        }
    }

    fn post(self: *@This(), amount: u16) void {
        if (self.use_spin)
            return self.spin.post(amount);

        {
            std.debug.assert(pthread_mutex_lock(&self.mutex) == 0);
            defer std.debug.assert(pthread_mutex_unlock(&self.mutex) == 0);

            const counter = self.spin.counter.get();
            self.spin.counter.set(counter + amount);
        }

        if (amount == 1) {
            std.debug.assert(pthread_cond_signal(&self.cond) == 0);
        } else {
            std.debug.assert(pthread_cond_broadcast(&self.cond) == 0);
        }
    }

    const pthread_cond_t = pthread_t;
    const pthread_condattr_t = pthread_t;

    const pthread_mutex_t = pthread_t;
    const pthread_mutexattr_t = pthread_t;

    extern "c" fn sched_yield() callconv(.C) c_int;
    const pthread_t = extern struct {
        _opaque: [128]u8 align(16),
    };

    extern "c" fn pthread_mutex_init(m: *pthread_mutex_t, a: ?*pthread_mutexattr_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_lock(m: *pthread_mutex_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_unlock(m: *pthread_mutex_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_destroy(m: *pthread_mutex_t) callconv(.C) c_int;

    extern "c" fn pthread_cond_init(c: *pthread_cond_t, a: ?*pthread_condattr_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_wait(noalias c: *pthread_cond_t, noalias m: *pthread_mutex_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_signal(c: *pthread_cond_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_broadcast(c: *pthread_cond_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_destroy(c: *pthread_cond_t) callconv(.C) c_int;
};