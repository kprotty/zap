const std = @import("std");
const core = @import("real_zap").core;

const Thread = std.Thread;
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

            if (new_tail != tail)
                self.tail.store(new_tail, .release);
            return first_task;
        }

        fn tryStealBounded(
            noalias self: *BoundedQueue,
            noalias target: *BoundedQueue,
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

                if (new_tail != tail)
                    self.tail.store(new_tail, .release);
                return first_task;
            }
        }
    };

    pub const Worker = struct {
        thread: ?*Thread = undefined,
        event: std.AutoResetEvent = std.AutoResetEvent{},
        idle_next: Atomic(usize) = Atomic(usize).init(0),
        scheduler: *Scheduler,
        target: ?*Worker = null,
        next: ?*Worker = undefined,
        runq_tick: usize = undefined,
        runq_lifo: Atomic(?*Task) = Atomic(?*Task).init(null),
        runq_next: ?*Task = null,
        run_queue: BoundedQueue = BoundedQueue{},

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

            var self = Worker{
                .scheduler = scheduler,
                .thread = thread,
            };

            self.runq_tick = @ptrToInt(&self);
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

            var is_waking = true;
            while (true) {
                if (self.poll(scheduler)) |task| {
                    if (is_waking)
                        scheduler.resumeWorker(is_waking);
                    is_waking = false;
                    self.runq_tick +%= 1;
                    resume task.frame;
                    continue;
                }

                is_waking = switch (scheduler.suspendWorker(&self, is_waking)) {
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

        fn schedule(self: *Worker, tasks: Batch, hints: ScheduleHints) void {
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
                if (self.runq_lifo.swap(batch.pop(), .release)) |old_lifo|
                    batch.pushFront(old_lifo);
            }

            const overflowed = self.run_queue.push(batch);
            const scheduler = self.scheduler;

            if (overflowed) |overflow_batch|
                scheduler.run_queue.push(overflow_batch);
            scheduler.resumeWorker(false);
        }

        fn poll(self: *Worker, scheduler: *Scheduler) ?*Task {
            if (self.runq_tick % 61 == 0) {
                if (self.run_queue.tryStealUnbounded(&scheduler.run_queue)) |task|
                    return task;
            }

            if (self.runq_next) |next| {
                const task = next;
                self.runq_next = null;
                return task;
            }

            if (self.runq_lifo.load(.relaxed) != null) {
                if (self.runq_lifo.swap(null, .relaxed)) |task|
                    return task;
            }
            
            if (self.run_queue.pop()) |task|
                return task;

            if (self.run_queue.tryStealUnbounded(&scheduler.run_queue)) |task|
                return task;

            var spawned_workers = blk: {
                const idle_queue = scheduler.idle_queue.load(.relaxed);
                const iq = Scheduler.IdleQueue.unpack(idle_queue);
                break :blk iq.spawned;
            };

            while (spawned_workers > 0) : (spawned_workers -= 1) {
                const target = self.target orelse blk: {
                    const target = scheduler.worker_queue.load(.consume);
                    self.target = target;
                    break :blk target orelse @panic("no running workers found when stealing");
                };

                self.target = target.next;
                if (target == self)
                    continue;

                if (self.run_queue.tryStealBounded(&target.run_queue)) |task|
                    return task;
                if (target.runq_lifo.load(.relaxed) != null) {
                    if (target.runq_lifo.swap(null, .acquire)) |task|
                        return task;
                }
            }

            if (self.run_queue.tryStealUnbounded(&scheduler.run_queue)) |task|
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
        idle_stack: Atomic(usize) = Atomic(usize).init(0),

        fn init(self: *Scheduler, max_workers: u16) void {
            self.* = Scheduler{};
            self.run_queue.init();
            self.max_workers = max_workers;
        }

        fn deinit(self: *Scheduler) void {
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
                        return self.notify();
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

        const Suspend = enum {
            retry,
            waking,
            shutdown,
        };

        fn suspendWorker(self: *Scheduler, worker: *Worker, is_waking: bool) Suspend {
            var idle_queue = self.idle_queue.load(.relaxed);

            while (true) {
                const iq = IdleQueue.unpack(idle_queue);
                const notified = iq.state != .shutdown and (
                    (iq.state == .suspend_notified) or
                    (is_waking and iq.state == .waking_notified)
                );

                var new_iq = iq;
                if (iq.state == .shutdown) {
                    new_iq.spawned -= 1;
                } else if (notified) {
                    new_iq.state = if (is_waking) .waking else .pending;
                } else {
                    new_iq.suspended += 1;
                    if (is_waking)
                        new_iq.state = .pending;
                }

                if (self.idle_queue.tryCompareAndSwap(
                    idle_queue,
                    new_iq.pack(),
                    .release,
                    .relaxed,
                )) |updated| {
                    idle_queue = updated;
                    continue;
                }

                if (iq.state != .shutdown) {
                    if (notified and !is_waking)
                        return .retry;
                    if (!notified)
                        self.wait(worker);
                    return .waking;
                }

                if (iq.spawned == 1) {
                    const main_worker = self.main_worker orelse @panic("no main worker when shutting down");
                    main_worker.event.set();
                }
                
                worker.event.wait();

                if (worker.thread == null) {
                    var workers = self.worker_queue.load(.consume);
                    while (workers) |idle_worker| {
                        const shutdown_worker = idle_worker;
                        workers = shutdown_worker.next;

                        const shutdown_thread = shutdown_worker.thread;
                        shutdown_worker.event.set();

                        if (shutdown_thread) |thread|
                            thread.wait();
                    }
                }

                return .shutdown;
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
                ) orelse return self.notifyAll();
            }
        }

        const IDLE_EMPTY: usize = 0;
        const IDLE_NOTIFIED: usize = 1;
        const IDLE_SHUTDOWN: usize = 2;

        fn wait(self: *Scheduler, worker: *Worker) void {
            var idle_stack = self.idle_stack.load(.relaxed);
            while (true) {
                if (idle_stack == IDLE_SHUTDOWN)
                    return;

                if (idle_stack == IDLE_NOTIFIED) {
                    idle_stack = self.idle_stack.tryCompareAndSwap(
                        idle_stack,
                        IDLE_EMPTY,
                        .acquire,
                        .relaxed,
                    ) orelse return;
                    continue;
                }

                worker.idle_next.store(idle_stack, .unordered);
                idle_stack = self.idle_stack.tryCompareAndSwap(
                    idle_stack,
                    @ptrToInt(worker),
                    .release,
                    .relaxed,
                ) orelse return worker.event.wait();
            }
        }
        
        fn notify(self: *Scheduler) void {
            var idle_stack = self.idle_stack.load(.consume);
            while (true) {
                if (idle_stack == IDLE_SHUTDOWN)
                    return;

                if (idle_stack == IDLE_EMPTY) {
                    idle_stack = self.idle_stack.tryCompareAndSwap(
                        idle_stack,
                        IDLE_NOTIFIED,
                        .release,
                        .consume,
                    ) orelse return;
                    continue;
                }

                const idle_worker = @intToPtr(*Worker, idle_stack);
                idle_stack = self.idle_stack.tryCompareAndSwap(
                    idle_stack,
                    idle_worker.idle_next.load(.unordered),
                    .acq_rel,
                    .consume,
                ) orelse return idle_worker.event.set();
            }
        }

        fn notifyAll(self: *Scheduler) void {
            var idle_stack = self.idle_stack.swap(IDLE_SHUTDOWN, .consume);
            if (idle_stack == IDLE_SHUTDOWN)
                @panic("notifyAll() called when already shutdown");
            if (idle_stack == IDLE_NOTIFIED)
                return;

            while (@intToPtr(?*Worker, idle_stack)) |idle_worker| {
                idle_stack = idle_worker.idle_next.load(.unordered);
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

// pub const Lock = switch (std.builtin.os.tag) {
//     .windows => struct {
//         srwlock: usize = 0,

//         extern "kernel32" fn AcquireSRWLockExclusive(p: *usize) callconv(.Stdcall) void;
//         extern "kernel32" fn ReleaseSRWLockExclusive(p: *usize) callconv(.Stdcall) void;

//         pub fn acquire(self: *Lock) void {
//             AcquireSRWLockExclusive(&self.srwlock);
//         }

//         pub fn release(self: *Lock) void {
//             ReleaseSRWLockExclusive(&self.srwlock);
//         }
//     },
//     else => struct {
//         mutex: std.Mutex = std.Mutex{},

//         pub fn acquire(self: *Lock) void {
//             _ = self.mutex.acquire();
//         }

//         pub fn release(self: *Lock) void {
//             (std.Mutex.Held{ .mutex = &self.mutex }).release();
//         }
//     },
// };