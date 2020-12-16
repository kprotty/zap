const builtin = @import("builtin");

const Event = @import("./event.zig").Event;
const Thread = @import("./thread.zig").Thread;
const atomic = @import("../../sync/sync.zig").atomic;

pub const Task = extern struct {
    next: ?*Task = undefined,
    callback: Callback,

    pub const Callback = fn(*Task) callconv(.C) void;

    pub fn init(callback: Callback) Task {
        return Task{ .callback = callback };
    }

    pub const Async = struct {
        task: Task = Task{ .callback = Async.callback },
        frame: anyframe,

        pub fn init(frame: anyframe) Async {
            return Async{ .frame = frame };
        }

        fn callback(task: *Task) callconv(.C) void {
            resume @fieldParentPtr(Async, "task", task).frame;
        }
    };

    pub const Batch = struct {
        head: ?*Task = null,
        tail: *Task = undefined,

        pub fn from(batchable: anytype) Batch {
            switch (@TypeOf(batchable)) {
                Batch => return batchable,
                ?*Task => return Batch.from(batchable orelse return Batch{}),
                *Task => {
                    batchable.next = null;
                    return Batch{
                        .head = batchable,
                        .tail = batchable,
                    };
                },
                else => |ty| @compileError(@typeName(ty) ++ " is not batchable"),
            }
        }

        pub fn isEmpty(self: Batch) bool {
            return self.head == null;
        }

        pub fn pushBack(self: *Batch, batchable: anytype) void {
            const batch = Batch.from(batchable);
            if (self.isEmpty()) {
                self.* = batch;
            } else if (!batch.isEmpty()) {
                self.tail.next = batch.head;
                self.tail = batch.tail;
            }
        }

        pub fn pushFront(self: *Batch, batchable: anytype) void {
            const batch = Batch.from(batchable);
            if (self.isEmpty()) {
                self.* = batch;
            } else if (!batch.isEmpty()) {
                batch.tail.next = self.head;
                self.head = batch.head;
            }
        }

        pub fn popFront(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }
    };
};

pub const Worker = struct {
    pool: *Pool,
    state: usize = undefined,
    active_next: ?*Worker = null,
    target_worker: ?*Worker = null,
    run_queue: BoundedQueue = BoundedQueue{},
    run_queue_lifo: ?*Task = null,
    run_queue_next: Task.Batch = Task.Batch{},
    run_queue_overflow: UnboundedQueue = UnboundedQueue{},

    threadlocal var tls_current: ?*Worker = null;

    pub fn getCurrent() ?*Worker {
        return tls_current;
    }

    pub fn getPool(self: *Worker) *Pool {
        return self.pool;
    }

    fn run(pool: *Pool) void {
        var self = Worker{ .pool = pool };
        self.state = blk: {
            const is_waking = true;
            const tick = @ptrToInt(&self);
            break :blk (tick << 1) | @boolToInt(is_waking);
        };

        const old_tls_current = tls_current;
        tls_current = &self;
        defer tls_current = old_tls_current;

        var active_queue = atomic.load(&pool.active_queue, .relaxed);
        while (true) {
            self.active_next = active_queue;
            active_queue = atomic.tryCompareAndSwap(
                &pool.active_queue,
                active_queue,
                &self,
                .release,
                .relaxed,
            ) orelse break;
        }

        while (true) {
            if (self.poll()) |task| {
                (task.callback)(task);
                continue;
            }

            const is_waking = pool.trySuspend(&self) orelse break;
            self.state &= ~@as(usize, 1);
            self.state |= @boolToInt(is_waking);
        }
    }

    pub fn poll(self: *Worker) ?*Task {
        var tick = self.state >> 1;
        var is_waking = self.state & 1 != 0;

        const pool = self.getPool();
        const task = self.pollRunnable(tick, pool) orelse return null;

        if (is_waking) {
            _ = pool.tryResume(self);
            is_waking = false;
        }

        tick += 1;
        if (tick >= ~@as(usize, 0) >> 1)
            tick = 0;

        self.state = (tick << 1) | @boolToInt(is_waking);
        return task;
    }

    fn pollRunnable(self: *Worker, tick: usize, pool: *Pool) ?*Task {
        if (tick % 61 == 0) {
            if (self.run_queue.popAndStealUnbounded(&pool.run_queue)) |task|
                return task;
            if (self.run_queue.popAndStealUnbounded(&self.run_queue_overflow)) |task|
                return task;
        }

        if (self.run_queue_next) |next| {
            const task = next;
            self.run_queue_next = null;
            return task;
        }

        if (atomic.load(&self.run_queue_lifo, .relaxed) != null) {
            if (atomic.swap(&self.run_queue_lifo, null, .consume)) |task|
                return task;
        }

        if (self.run_queue.pop()) |task| {
            return task;
        }

        if (self.run_queue.popAndStealUnbounded(&self.run_queue_overflow)) |task|
            return task;

        if (self.run_queue.popAndStealUnbounded(&pool.run_queue)) |task|
            return task;
            
        var num_workers = Pool.IdleQueue.unpack(atomic.load(&pool.idle_queue, .relaxed)).spawned;
        while (num_workers > 0) : (num_workers -= 1) {
            const target_worker = self.target_worker
                orelse atomic.load(&pool.active_queue, .consume)
                orelse @panic("no active workers when work-stealing");

            self.target_worker = target_worker.active_next;
            if (target_worker == self)
                continue;

            if (self.run_queue.popAndStealBounded(&target_worker.run_queue)) |task|
                return task;

            if (self.run_queue.popAndStealUnbounded(&target_worker.run_queue_overflow)) |task|
                return task;

            if (atomic.load(&target_worker.run_queue_lifo, .relaxed) != null) {
                atomic.spinLoopHint();
                if (atomic.swap(&target_worker.run_queue_lifo, null, .consume)) |task|
                    return task;
            }
        }

        if (self.run_queue.popAndStealUnbounded(&pool.run_queue)) |task|
            return task;

        return null;
    }

    pub const ScheduleHint = enum {
        // schedule the tasks to be executed as soon as possible on the local Worker
        next,
        // schedule the tasks to be executed before existing scheduled tasks excluding those scheduled with `next`
        lifo,
        // schedule the tasks to be executed in general after any other scheduled tasks
        fifo,
        // schedule the tasks to either be run next or after existing tasks in the system if there are any
        yield,
    };

    pub fn schedule(self: *Worker, hint: ScheduleHint, batchable: anytype) void {
        var sched_hint = hint;
        var batch = Task.Batch.from(batchable);
        
        while (!batch.isEmpty()) {
            switch (sched_hint) {
                .next => {
                    self.run_queue_next.push(batch);
                    return;
                },
                .lifo => {
                    defer _ = self.getPool().tryResume(self);
                    var run_queue_lifo = atomic.load(&self.run_queue_lifo, .relaxed);
                    while (true) {
                        batch.tail.next = run_queue_lifo;
                        
                        if (run_queue_lifo == null) {
                            atomic.store(&self.run_queue_lifo, batch.head, .release);
                            return;
                        }

                        run_queue_lifo = atomic.tryCompareAndSwap(
                            &self.run_queue_lifo,
                            run_queue_lifo,
                            batch.head,
                            .release,
                            .relaxed,
                        ) orelse return;
                    }
                },
                .fifo => {
                    if (self.run_queue.push(batch)) |overflowed|
                        self.run_queue_overflow.push(overflowed);
                    _ = self.getPool().tryResume(self);
                    return;
                },
                .yield => {
                    const new_next = self.poll() orelse batch.popFront();
                    batch.pushFront(new_next);
                    sched_hint = .next;
                    continue;
                },
            }
        }
    }
};

pub const Pool = struct {
    stack_size: u32,
    max_workers: u16,
    shutdown_event: ?*Event = null,
    idle_queue: u32 = 0,
    active_queue: ?*Worker = null,
    wait_queue: WaitQueue = WaitQueue{},
    run_queue: UnboundedQueue = UnboundedQueue{},
    
    const IdleQueue = struct {
        idle: u16 = 0,
        spawned: u16 = 0,
        notified: bool = false,
        state: State = .pending,

        const State = enum(u3) {
            pending = 0,
            notified,
            waking,
            waker_notified,
            shutdown,
        };

        fn pack(self: IdleQueue) u32 {
            var value: u32 = 0;
            value |= @enumToInt(self.state);
            value |= @as(u32, @boolToInt(self.notified)) << 3;
            value |= @as(u32, @intCast(u14, self.idle)) << 4;
            value |= @as(u32, @intCast(u14, self.spawned)) << (14 + 4);
            return value;
        }

        fn unpack(value: u32) IdleQueue {
            return IdleQueue{
                .state = @intToEnum(State, @truncate(u3, value)),
                .notified = value & (1 << 3) != 0,
                .idle = @truncate(u14, value >> 4),
                .spawned = @truncate(u14, value >> (4 + 14)),
            };
        }
    };

    pub const Config = struct {
        max_threads: ?u16 = null,
        stack_size: ?u32 = null,
    };

    pub fn run(config: Config, batchable: anytype) void {
        const batch = Task.Batch.from(batchable);
        if (batch.isEmpty())
            return;

        const max = struct {
            fn max(x: anytype, y: anytype) @TypeOf(y) {
                return if (x > y) x else y;
            }
        }.max;

        const stack_size: u32 =
            if (config.stack_size) |stack_size|
                max(16 * 1024, stack_size)
            else
                @as(u32, 1 * 1024 * 1024);

        const max_threads: u16 =
            if (builtin.single_threaded) 
                @as(u16, 1)
            else if (config.max_threads) |max_threads|
                max(1, max_threads)
            else
                @intCast(u16, Thread.getCpuCount()); 

        var pool = Pool{
            .stack_size = stack_size,
            .max_workers = max_threads,
        };

        pool.run_queue.push(batch);
        _ = pool.tryResume(null);
    }

    pub fn schedule(self: *Pool, batchable: anytype) void {
        const batch = Task.Batch.from(batchable);
        if (batch.isEmpty())
            return;

        self.run_queue.push(batch);
        _ = self.tryResume(null);
    }

    fn tryResume(self: *Pool, worker: ?*Worker) bool {
        var remaining_attempts: u8 = 5;
        var is_waking = if (worker) |w| (w.state & 1 != 0) else false;
        var idle_queue = IdleQueue.unpack(atomic.load(&self.idle_queue, .relaxed));

        while (true) {
            if (idle_queue.state == .shutdown)
                return false;

            const can_wake = (idle_queue.idle > 0 or idle_queue.spawned < self.max_workers);
            if (can_wake and (
                (is_waking and remaining_attempts > 0) or
                (!is_waking and idle_queue.state == .pending)
            )) {
                var new_idle_queue = idle_queue;
                new_idle_queue.state = .waking;
                if (idle_queue.idle > 0) {
                    new_idle_queue.idle -= 1;
                    new_idle_queue.notified = true;
                } else {
                    new_idle_queue.spawned += 1;
                }

                if (atomic.tryCompareAndSwap(
                    &self.idle_queue,
                    idle_queue.pack(),
                    new_idle_queue.pack(),
                    .acquire,
                    .relaxed,
                )) |updated| {
                    idle_queue = IdleQueue.unpack(updated);
                    continue;
                }

                if (idle_queue.idle > 0) {
                    self.idleNotify();
                    return true;
                }

                if (builtin.single_threaded or idle_queue.spawned == 0) {
                    Worker.run(self);
                    return true;
                }

                if (Thread.spawn(self.stack_size, self, Worker.run)) |_| {
                    return true;
                } else |_| {}

                is_waking = true;
                remaining_attempts -= 1;
                atomic.spinLoopHint();
                idle_queue = IdleQueue.unpack(atomic.load(&self.idle_queue, .relaxed));
                continue;
            }

            var new_idle_queue = idle_queue;
            new_idle_queue.state = blk: {
                if (is_waking and can_wake)
                    break :blk IdleQueue.State.pending;
                if (is_waking or idle_queue.state == .pending)
                    break :blk IdleQueue.State.notified;
                if (idle_queue.state == .waking)
                    break :blk IdleQueue.State.waker_notified;
                return false;
            };

            if (atomic.tryCompareAndSwap(
                &self.idle_queue,
                idle_queue.pack(),
                new_idle_queue.pack(),
                .relaxed,
                .relaxed,
            )) |updated| {
                idle_queue = IdleQueue.unpack(updated);
                continue;
            }

            return true;
        }
    }

    fn trySuspend(self: *Pool, worker: *Worker) ?bool {
        const is_waking = worker.state & 1 != 0;
        var idle_queue = IdleQueue.unpack(atomic.load(&self.idle_queue, .relaxed));

        while (true) {
            const can_wake = idle_queue.idle > 0 or idle_queue.spawned < self.max_workers;
            const is_shutdown = idle_queue.state == .shutdown;
            const is_notified = switch (idle_queue.state) {
                .waker_notified => is_waking,
                .notified => true,
                else => false,
            };

            var new_idle_queue = idle_queue;
            if (is_shutdown) {
                new_idle_queue.spawned -= 1;
            } else if (is_notified) {
                new_idle_queue.state = if (is_waking) .waking else .pending;
            } else {
                new_idle_queue.idle += 1;
                if (is_waking)
                    new_idle_queue.state = if (can_wake) .pending else .notified;
            }

            if (atomic.tryCompareAndSwap(
                &self.idle_queue,
                idle_queue.pack(),
                new_idle_queue.pack(),
                .acq_rel,
                .relaxed,
            )) |updated| {
                idle_queue = IdleQueue.unpack(updated);
                continue;
            }

            if (is_notified and is_waking)
                return true;
            if (is_notified)
                return false;

            if (!is_shutdown) {
                self.idleWait(worker);
                return true;
            }

            // if this is the last worker to shutdown from the pool, notify the root worker
            const was_last_worker = new_idle_queue.spawned == 0;
            if (was_last_worker) {
                if (atomic.swap(&self.shutdown_event, &@as(Event, undefined))) |root_worker_event| {
                    root_worker_event.notify();
                }
            }

            // if this is the root worker, wait for all workers to have shutdown from (& stop being able to reference) the pool.
            const is_root_worker = worker.active_next == null;
            if (is_root_worker) {
                var event = Event{};
                event.wait(null, struct {
                    pool: *Pool,
                    ptr: *Event,
                    pub fn wait(this: @This()) bool {
                        return atomic.swap(&this.pool.shutdown_event, this.ptr, .release) == null;
                    }
                }{
                    .pool = self,
                    .ptr = &event,
                }) catch unreachable;
            }

            return null;
        }
    }

    pub fn shutdown(self: *Pool) void {
        @setCold(true);

        var idle_queue = IdleQueue.unpack(atomic.load(&self.idle_queue, .relaxed));
        while (true) {
            if (idle_queue.state == .shutdown)
                return;

            var new_idle_queue = idle_queue;
            new_idle_queue.state = .shutdown;
            new_idle_queue.notified = false;

            if (atomic.tryCompareAndSwap(
                &self.idle_queue,
                idle_queue.pack(),
                new_idle_queue.pack(),
                .relaxed,
                .relaxed,
            )) |updated| {
                idle_queue = IdleQueue.unpack(updated);
                continue;
            }

            self.idleShutdown();
            return;
        }
    }

    fn idleWait(self: *Pool, worker: *Worker) void {
        @setCold(true);

        // TODO: use io-driver if enabled from pool init instead of wait_queue
        // TODO: re-use wait_queue ptr as io-driver ptr?

        var idle_queue = IdleQueue.unpack(atomic.load(&self.idle_queue, .relaxed));
        while (true) {
            if (idle_queue.state == .shutdown)
                return;

            if (idle_queue.notified) {
                var new_idle_queue = idle_queue;
                new_idle_queue.notified = false;
                idle_queue = IdleQueue.unpack(atomic.tryCompareAndSwap(
                    &self.idle_queue,
                    idle_queue,
                    new_idle_queue,
                    .relaxed,
                    .relaxed,
                ) orelse return);
                continue;
            }

            self.wait_queue.wait(struct {
                pool: *Pool,
                pub fn validate(self: @This()) bool {
                    const idleq = IdleQueue.unpack(atomic.load(&self.pool.idle_queue, .relaxed));
                    return !(idleq.state == .shutdown or idleq.notified);
                }
            }{ .pool = self });

            atomic.spinLoopHint();
            idle_queue = IdleQueue.unpack(atomic.load(&self.idle_queue, .relaxed));
        }
    }

    fn idleNotify(self: *Pool) void {
        @setCold(true);
        self.wait_queue.notify();
    }

    fn idleShutdown(self: *Pool) void {
        @setCold(true);
        self.wait_queue.shutdown();
    }
};

const WaitQueue = struct {
    state: usize = EMPTY,

    const EMPTY: usize = 0;
    const NOTIFIED: usize = 1;
    const SHUTDOWN: usize = 2;
    const WAITING: usize = ~(EMPTY | NOTIFIED | SHUTDOWN);

    const Waiter = struct {
        next: ?*Waiter align(if (@alignOf(usize) < 4) 4 else @alignOf(usize)),
        event: Event,
    };

    fn wait(self: *WaitQueue, wait_validator: anytype) void {
        var has_event = false;
        var waiter: Waiter = undefined;
        var state = atomic.load(&self.state, .relaxed);

        while (true) {
            if (!wait_validator.validate())
                return;

            if (state & SHUTDOWN != 0)
                return;

            const head = @intToPtr(?*Waiter, state & WAITING);
            if (state & NOTIFIED != 0 and head == null) {
                state = atomic.tryCompareAndSwap(
                    &self.state,
                    state,
                    state & ~NOTIFIED,
                    .relaxed,
                    .relaxed,
                ) orelse return;
                continue;
            }

            waiter.next = head;
            if (!has_event) {
                has_event = true;
                waiter.event = Event{};
            }

            if (atomic.tryCompareAndSwap(
                &self.state,
                state,
                (state & ~WAITING) | @ptrToInt(&waiter),
                .release,
                .relaxed,
            )) |updated| {
                state = updated;
                continue;
            }

            return waiter.event.wait(null, struct {
                pub fn wait(self: @This()) bool {
                    return true;
                }
            }{}) catch unreachable;
        }
    }
    
    fn notify(self: *WaitQueue) void {
        var state = atomic.load(&self.state, .relaxed);
        while (true) {
            if (state & (SHUTDOWN | NOTIFIED) != 0)
                return;

            if (atomic.tryCompareAndSwap(
                &self.state,
                state,
                state | NOTIFIED,
                .acquire,
                .relaxed,
            )) |updated| {
                state = updated;
                continue;
            }

            while (true) {
                const waiter = @intToPtr(?*Waiter, state & WAITING) orelse return;
                state = atomic.tryCompareAndSwap(
                    &self.state,
                    state,
                    (state & ~(WAITING | NOTIFIED)) | @ptrToInt(&waiter.next),
                    .release,
                    .relaxed,
                ) orelse return waiter.event.notify();
                if (state & SHUTDOWN != 0)
                    break;
            }

            var waiters = @intToPtr(?*Waiter, state & WAITING);
            while (true) {
                const waiter = waiters orelse return;
                waiters = waiter.next;
                waiter.event.notify();
            }
        }
    }

    fn shutdown(self: *WaitQueue) void {
        const state = atomic.fetchOr(&self.state, SHUTDOWN, .acquire);
        if (state & NOTIFIED != 0)
            return;

        var waiters = @intToPtr(?*Waiter, state & WAITING);
        while (true) {
            const waiter = waiters orelse return;
            waiters = waiter.next;
            waiter.event.notify();
        }
    }
};

const UnboundedQueue = struct {
    head: usize = 0,
    tail: ?*Task = null,
    stub_next: ?*Task = null,

    fn push(self: *UnboundedQueue, batchable: anytype) void {
        const batch = Task.Batch.from(batchable);
        if (batch.isEmpty())
            return;

        batch.tail.next = null;
        const prev_tail = atomic.swap(&self.tail, batch.tail, .acq_rel);
        const prev = prev_tail orelse @fieldParentPtr(Task, "next", &self.stub_next);
        atomic.store(&prev.next, batch.head, .release);
    }

    const IS_CONSUMING: usize = 1;

    fn tryAcquireConsumer(self: *UnboundedQueue) ?Consumer {
        const stub = @fieldParentPtr(Task, "next", &self.stub_next);
        var head = atomic.load(&self.head, .relaxed);

        while (true) {
            if (head & IS_CONSUMING != 0)
                return null;
            
            const tail = atomic.load(&self.tail, .relaxed);
            if (tail == @as(?*Task, stub) or tail == null)
                return null;

            head = atomic.tryCompareAndSwap(
                &self.head,
                head,
                head | IS_CONSUMING,
                .acquire,
                .relaxed,
            ) orelse return Consumer{
                .queue = self,
                .stub = stub,
                .head = @intToPtr(?*Task, head & ~IS_CONSUMING) orelse stub,
            };
        }
    }

    const Consumer = struct {
        queue: *UnboundedQueue,
        stub: *Task,
        head: *Task,

        fn release(self: Consumer) void {
            const new_head = @ptrToInt(self.head);
            atomic.store(&self.queue.head, new_head, .release);
        }

        fn pop(self: *Consumer) ?*Task {
            var head = self.head;
            var next = atomic.load(&head.next, .acquire);

            if (head == self.stub) {
                head = next orelse return null;
                self.head = head;
                next = atomic.load(&head.next, .acquire);
            }

            if (next) |new_head| {
                self.head = new_head;
                return head;
            }

            const tail = atomic.load(&self.queue.tail, .relaxed);
            if (head != tail)
                return null;

            self.queue.push(self.stub);

            next = atomic.load(&head.next, .acquire);
            if (next) |new_head| {
                self.head = new_head;
                return head;
            }

            return null;
        }
    };
};

const BoundedQueue = struct {
    head: usize = 0,
    tail: usize = 0,
    buffer: [256]*Task = undefined,

    fn push(self: *BoundedQueue, batchable: anytype) ?Task.Batch {
        var batch = Task.Batch.from(batchable);
        if (batch.isEmpty())
            return null;

        var tail = self.tail;
        var head = atomic.load(&self.head, .relaxed);
        while (true) {
            if (batch.isEmpty())
                return null;

            const size = tail -% head;
            var remaining = self.buffer.len - size;
            if (remaining > 0) {
                while (remaining > 0) : (remaining -= 1) {
                    const task = batch.popFront() orelse break;
                    const slot = &self.buffer[tail % self.buffer.len];
                    atomic.store(slot, task, .unordered);
                    tail +%= 1;
                }

                atomic.store(&self.tail, tail, .release);
                atomic.spinLoopHint();
                head = atomic.load(&self.head, .relaxed);
                continue;
            }

            const migrate = @as(u32, self.buffer.len / 2);
            const new_head = head +% migrate;
            if (atomic.tryCompareAndSwap(
                &self.head,
                head,
                new_head,
                .acquire,
                .relaxed,
            )) |updated| {
                head = updated;
                continue;
            }

            var overflowed = Task.Batch{};
            while (head != new_head) : (head +%= 1) {
                const task = self.buffer[head % self.buffer.len];
                overflowed.pushBack(task);
            }

            overflowed.pushBack(batch);
            return overflowed;
        }
    }

    fn pop(self: *BoundedQueue) ?*Task {
        const tail = self.tail;
        var head = atomic.load(&self.head, .relaxed);

        while (true) {
            if (tail == head)
                return null;

            if (atomic.tryCompareAndSwap(
                &self.head,
                head,
                head +% 1,
                .acquire,
                .relaxed,
            )) |updated| {
                head = updated;
                continue;
            }

            return self.buffer[head % self.buffer.len];
        }
    }

    fn popAndStealUnbounded(self: *BoundedQueue, target_queue: *UnboundedQueue) ?*Task {
        var consumer = target_queue.tryAcquireConsumer() orelse return null;
        defer consumer.release();

        var tail = self.tail;
        var new_tail = tail;
        var first_task: ?*Task = null;
        var head = atomic.load(&self.head, .relaxed);
        
        while (true) {
            if (first_task != null and (new_tail -% head >= self.buffer.len)) {
                atomic.spinLoopHint();
                head = atomic.load(&self.head, .relaxed);
                if (new_tail -% head < self.buffer.len)
                    continue;
                break;
            }

            const task = consumer.pop() orelse break;
            if (first_task == null) {
                first_task = task;
                continue;
            }

            const slot = &self.buffer[new_tail % self.buffer.len];
            atomic.store(slot, task, .unordered);
            new_tail +%= 1;
        }

        if (new_tail != tail)
            atomic.store(&self.tail, new_tail, .release);
        return first_task;
    }

    fn popAndStealBounded(self: *BoundedQueue, target_queue: *BoundedQueue) ?*Task {
        const tail = self.tail;
        const head = atomic.load(&self.head, .relaxed);
        if (tail != head)
            return self.pop();

        var target_head = atomic.load(&target_queue.head, .acquire);
        while (true) {
            const target_tail = atomic.load(&target_queue.tail, .acquire);
            if (target_head == target_tail)
                return null;

            const size = target_tail -% target_head;
            var steal = size - (size / 2);
            if (steal > self.buffer.len / 2) {
                atomic.spinLoopHint();
                target_head = atomic.load(&target_queue.head, .acquire);
                continue;
            }

            var new_target_head = target_head;
            const first_task = blk: {
                const slot = &target_queue.buffer[new_target_head % target_queue.buffer.len];
                const task = atomic.load(slot, .unordered);
                new_target_head +%= 1;
                steal -= 1;
                break :blk task;
            };

            var new_tail = tail;
            while (steal > 0) : (steal -= 1) {
                const task = atomic.load(&target_queue.buffer[new_target_head % target_queue.buffer.len], .unordered);
                atomic.store(&self.buffer[new_tail % self.buffer.len], task, .unordered);
                new_target_head +%= 1;
                new_tail +%= 1;
            }

            if (atomic.tryCompareAndSwap(
                &target_queue.head,
                target_head,
                new_target_head,
                .acq_rel,
                .acquire,
            )) |updated| {
                target_head = updated;
                continue;
            }

            if (new_tail != tail)
                atomic.store(&self.tail, new_tail, .release);
            return first_task;
        }
    }
};