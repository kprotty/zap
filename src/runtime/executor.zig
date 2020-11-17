const std = @import("std");

const atomic = @import("../sync/sync.zig").core.atomic;
const spinLoopHint = atomic.spinLoopHint;
const Atomic = atomic.Atomic;

pub const Task = struct {
    next_ptr: ?*Task = undefined,
    runnable: usize,

    pub fn init(frame: anyframe) Task {
        if (@alignOf(anyframe) < 2)
            @compileError("anyframe does not support a large enough alignment");
        return Task{ .runnable = @ptrToInt(frame) };
    }

    pub const Callback = fn(*Task) callconv(.C) void;

    pub fn initCallback(callback: Callback) Task {
        if (@alignOf(Callback) < 2)
            @compileError(@typeName(Callback) ++ " does not support a large enough alignment");
        return Task{ .runnable = @ptrToInt(callback) | 1 };
    }

    pub fn execute(self: *Task) void {
        if (self.runnable & 1 != 0) {
            const callback = @intToPtr(Callback, self.runnable & ~@as(usize, 1));
            return (callback)(self);
        }

        const frame = @intToPtr(anyframe, self.runnable);
        resume frame;
    }

    pub fn toBatch(self: *Task) Batch {
        return Batch.from(self);
    }

    inline fn next(self: *Task) *Atomic(?*Task) {
        return @ptrCast(*Atomic(?*Task), &self.next_ptr);
    }
};

pub const Batch = struct {
    head: ?*Task = null,
    tail: *Task = undefined,

    pub fn from(batchable: anytype) Batch {
        if (@TypeOf(batchable) == Batch)
            return batchable;

        if (@TypeOf(batchable) == *Task) {
            batchable.next().set(null);
            return Batch{
                .head = batchable,
                .tail = batchable,
            };
        }

        if (@TypeOf(batchable) == ?*Task) {
            const task: *Task = batchable orelse return Batch{};
            return Batch.from(task);
        }

        @compileError(@typeName(@TypeOf(batchable)) ++ " cannot be converted into a " ++ @typeName(Batch));
    }

    pub fn isEmpty(self: Batch) bool {
        return self.head == null;
    }

    pub fn push(self: *Batch, entity: anytype) void {
        return self.pushBack(entity);
    }

    pub fn pushBack(self: *Batch, entity: anytype) void {
        const other = Batch.from(entity);
        if (self.isEmpty()) {
            self.* = other;
        } else {
            self.tail.next().set(other.head);
            self.tail = other.tail;
        }
    }

    pub fn pushFront(self: *Batch, entity: anytype) void {
        const other = Batch.from(entity);
        if (self.isEmpty()) {
            self.* = other;
        } else {
            other.tail.next().set(self.head);
            self.head = other.head;
        }
    }

    pub fn pop(self: *Batch) ?*Task {
        return self.popFront();
    }

    pub fn popFront(self: *Batch) ?*Task {
        const task = self.head orelse return null;
        self.head = task.next().get();
        return task;
    }
};

pub const Worker = struct {
    event: std.AutoResetEvent align(EVENT_ALIGN) = std.AutoResetEvent{},
    run_queue_lifo: Atomic(?*Task) = Atomic(?*Task).init(null),
    run_queue_overflow: UnboundedTaskQueue = undefined,
    run_queue: BoundedTaskQueue = undefined,
    active_next: ?*Worker = null,
    idle_next: ?*Worker = null,
    scheduler: *Scheduler,
    thread: ?*std.Thread,

    const EVENT_ALIGN = std.math.max(
        ~Scheduler.IDLE_WAITING + 1,
        @alignOf(std.AutoResetEvent),
    );

    threadlocal var tls_current: ?*Worker = null;

    fn spawn(scheduler: *Scheduler) bool {
        const Spawner = struct {
            scheduler: *Scheduler,
            thread: *std.Thread = undefined,
            thread_event: std.AutoResetEvent = std.AutoResetEvent{},
            spawn_event: std.AutoResetEvent = std.AutoResetEvent{},

            fn entry(self: *@This()) void {
                self.thread_event.wait();
                const thread = self.thread;
                const sched = self.scheduler;
                self.spawn_event.set();
                return Worker.run(sched, thread);
            }
        };

        var spawner = Spawner{ .scheduler = scheduler };
        spawner.thread = std.Thread.spawn(&spawner, Spawner.entry) catch return false;
        spawner.thread_event.set();
        spawner.spawn_event.wait();
        return true;
    }

    fn run(scheduler: *Scheduler, thread: ?*std.Thread) void {
        var self = Worker{ .scheduler = scheduler, .thread = thread };
        self.run_queue_overflow.init();
        self.run_queue.init();

        const old_tls_current = tls_current;
        tls_current = &self;
        defer tls_current = old_tls_current;

        var active_queue = scheduler.active_queue().load(.relaxed);
        while (true) {
            self.active_next = active_queue;
            active_queue = scheduler.active_queue().tryCompareAndSwap(
                active_queue,
                &self,
                .release,
                .relaxed,
            ) orelse break;
        }

        var is_resuming = true;
        var worker_iter = scheduler.getWorkers();
        var run_tick = @ptrToInt(&self) ^ @ptrToInt(scheduler);

        while (true) {
            if (self.poll(scheduler, run_tick, &worker_iter)) |task| {
                if (is_resuming) {
                    is_resuming = false;
                    _ = scheduler.tryResumeWorker(true);
                }

                run_tick +%= 1;
                task.execute();
                continue;
            }

            is_resuming = switch (scheduler.trySuspendWorker(&self, is_resuming)) {
                .retry => false,
                .resumed => true,
                .shutdown => break,
            };
        }
    }

    inline fn poll(self: *Worker, scheduler: *Scheduler, tick: usize, workers: *Scheduler.WorkerIter) ?*Task {
        // TODO: poll for io/timers here if single threaded

        if (tick % 61 == 0) {
            if (self.run_queue.popAndStealFromUnbounded(&scheduler.run_queue)) |task| {
                return task;
            }
        }

        if (tick % 31 == 0) {
            if (self.run_queue.popAndStealFromUnbounded(&self.run_queue_overflow)) |task| {
                return task;
            }
        }

        if (self.run_queue_lifo.load(.relaxed) != null) {
            if (self.run_queue_lifo.swap(null, .acquire)) |lifo_task| {
                return lifo_task;
            }
        }

        if (self.run_queue.pop()) |task| {
            return task;
        }

        if (self.run_queue.popAndStealFromUnbounded(&self.run_queue_overflow)) |task| {
            return task;
        }

        if (self.run_queue.popAndStealFromUnbounded(&scheduler.run_queue)) |task| {
            return task;
        }

        var active_workers = scheduler.getActiveWorkers();
        while (active_workers > 0) : (active_workers -= 1) {

            const target_worker = workers.next() orelse blk: {
                workers.* = scheduler.getWorkers();
                break :blk workers.next() orelse unreachable;
            };

            if (target_worker == self)
                continue;

            if (self.run_queue.popAndStealFromBounded(&target_worker.run_queue)) |task|
                return task;

            if (self.run_queue.popAndStealFromUnbounded(&target_worker.run_queue_overflow)) |task|
                return task;

            if (target_worker.run_queue_lifo.load(.relaxed) != null) {
                if (target_worker.run_queue_lifo.swap(null, .acquire)) |lifo_task| {
                    return lifo_task;
                }
            }
        }

        if (self.run_queue.popAndStealFromUnbounded(&scheduler.run_queue)) |task| {
            return task;
        }

        return null;
    }

    pub fn getCurrent() ?*Worker {
        return tls_current;
    }

    pub fn getScheduler(self: *Worker) *Scheduler {
        return self.scheduler;
    }

    pub fn getAllocator(self: *Worker) *std.mem.Allocator {
        // TODO: thread-local allocator based on mimalloc
        return @import("./heap.zig").getAllocator();
    }

    pub const ScheduleHints = struct {
        use_lifo: bool = false,
    };

    pub fn schedule(self: *Worker, tasks: Batch, hints: ScheduleHints) void {
        var batch = tasks;
        if (batch.isEmpty())
            return;

        if (hints.use_lifo) {
            if (self.run_queue_lifo.swap(batch.pop(), .acq_rel)) |old_lifo|
                batch.pushFront(old_lifo);
        }

        if (!batch.isEmpty()) {
            if (self.run_queue.push(batch)) |overflowed|
                self.run_queue_overflow.push(overflowed);
        }

        const scheduler = self.getScheduler();
        _ = scheduler.tryResumeWorker(false);
    }
};

pub const Scheduler = struct {
    max_workers: u16,
    main_worker: ?*Worker = null,
    idle_queue: Atomic(usize) = Atomic(usize).init(IDLE_EMPTY),
    active_queue_ptr: ?*Worker = null,
    counter: Atomic(u32) = Atomic(u32).init((Counter{}).pack()),
    run_queue: UnboundedTaskQueue = undefined,

    const Counter = struct {
        idle: u16 = 0,
        spawned: u16 = 0,
        state: State = .pending,

        const State = enum(u4) {
            pending = 0,
            resuming,
            resumer_notified,
            suspend_notified,
            shutdown,
        };

        fn pack(self: Counter) u32 {
            var value: u32 = 0;
            value |= @as(u32, @enumToInt(self.state));
            value |= @as(u32, @intCast(u14, self.idle)) << 4;
            value |= @as(u32, @intCast(u14, self.spawned)) << (4 + 14);
            return value;
        }

        fn unpack(value: u32) Counter {
            var self: Counter = undefined;
            self.state = @intToEnum(State, @truncate(u4, value));
            self.idle = @truncate(u14, value >> 4);
            self.spawned = @truncate(u14, value >> (4 + 14));
            return self;
        }
    }; 

    pub const RunConfig = struct {
        max_threads: ?u16 = null,
    };

    pub fn run(config: RunConfig, batch: Batch) void {
        if (batch.isEmpty())
            return;

        const max_threads = std.math.min(std.math.maxInt(u14), (
            if (std.builtin.single_threaded) 
                @as(u16, 1)
            else if (config.max_threads) |max_threads|
                std.math.max(1, max_threads)
            else 
                @intCast(u16, std.Thread.cpuCount() catch 1)
        ));

        var self = Scheduler{ .max_workers = max_threads };
        self.run_queue.init();
        self.schedule(batch);
    }

    inline fn active_queue(self: *Scheduler) *Atomic(?*Worker) {
        return @ptrCast(*Atomic(?*Worker), &self.active_queue_ptr);
    }

    pub fn getWorkers(self: *Scheduler) WorkerIter {
        const active_worker = self.active_queue().load(.acquire);
        return WorkerIter{ .worker = active_worker };
    }

    pub const WorkerIter = struct {
        worker: ?*Worker,

        pub fn next(self: *WorkerIter) ?*Worker {
            const worker = self.worker orelse return null;
            self.worker = worker.active_next;
            return worker;
        }
    };

    fn getActiveWorkers(self: *const Scheduler) u16 {
        const count = self.counter.load(.acquire);
        const counter = Counter.unpack(count);
        return counter.spawned;
    }

    pub fn schedule(self: *Scheduler, batch: Batch) void {
        self.run_queue.push(batch);
        _ = self.tryResumeWorker(false);
    }

    fn tryResumeWorker(self: *Scheduler, is_caller_resuming: bool) bool {
        const max_workers = self.max_workers;

        var remaining_attempts: u8 = 3;
        var is_resuming = is_caller_resuming;
        var counter = Counter.unpack(self.counter.load(.acquire));

        while (true) {
            if (counter.state == .shutdown) {
                return false;
            }
            
            const has_resumables = (counter.idle > 0 or counter.spawned < max_workers);
            if (has_resumables and (
                (is_resuming and remaining_attempts > 0) or
                (!is_resuming and counter.state == .pending)
            )) {
                var new_counter = counter;
                new_counter.state = .resuming;
                if (counter.idle > 0) {
                    new_counter.idle -= 1;
                } else {
                    new_counter.spawned += 1;
                }

                if (self.counter.tryCompareAndSwap(
                    counter.pack(),
                    new_counter.pack(),
                    .acq_rel,
                    .acquire,
                )) |updated| {
                    counter = Counter.unpack(updated);
                    continue;
                } else {
                    is_resuming = true;
                }

                if (counter.idle > 0) {
                    self.idleNotify();
                    return true;
                }

                if (std.builtin.single_threaded or counter.spawned == 0) {
                    Worker.run(self, null);
                    return true;
                }

                if (Worker.spawn(self)) {
                    return true;
                }

                spinLoopHint();
                remaining_attempts -= 1;
                counter = Counter.unpack(self.counter.load(.acquire));
                continue;
            }

            var new_state: Counter.State = undefined;
            if (is_resuming and has_resumables) {
                new_state = .pending;
            } else if (is_resuming or counter.state == .pending) {
                new_state = .suspend_notified;
            } else if (counter.state == .resuming) {
                new_state = .resumer_notified;
            } else {
                return false;
            }

            var new_counter = counter;
            new_counter.state = new_state;
            if (self.counter.tryCompareAndSwap(
                counter.pack(),
                new_counter.pack(),
                .acq_rel,
                .acquire,
            )) |updated| {
                counter = Counter.unpack(updated);
                continue;
            }

            return true;
        }
    }

    const Suspend = enum {
        retry,
        resumed,
        shutdown,
    };

    fn trySuspendWorker(self: *Scheduler, worker: *Worker, is_resuming: bool) Suspend {
        const max_workers = self.max_workers;
        const is_main_worker = worker.thread == null;
        var counter = Counter.unpack(self.counter.load(.acquire));

        while (true) {
            const has_resumables = counter.idle > 0 or counter.spawned < max_workers;
            const is_shutdown = counter.state == .shutdown;
            const is_notified = switch (counter.state) {
                .resumer_notified => is_resuming,
                .suspend_notified => true,
                else => false,
            };

            var new_counter = counter;
            if (is_shutdown) {
                new_counter.spawned -= 1;
            } else if (is_notified) {
                new_counter.state = if (is_resuming) .resuming else .pending;
            } else {
                new_counter.state = if (has_resumables) .pending else .suspend_notified;
                new_counter.idle += 1;
            }

            if (is_main_worker) {
                self.main_worker = worker;
            }

            if (self.counter.tryCompareAndSwap(
                counter.pack(),
                new_counter.pack(),
                .acq_rel,
                .acquire,
            )) |updated| {
                counter = Counter.unpack(updated);
                continue;
            }

            if (is_notified and is_resuming)
                return .resumed;
            if (is_notified)
                return .retry;

            if (!is_shutdown) {
                self.idleWait(worker);
                return .resumed;
            }

            if (new_counter.spawned == 0) {
                const main_worker = self.main_worker orelse {
                    std.debug.panic("Scheduler shutting down without a main worker", .{});
                };
                main_worker.event.set();
            }

            worker.event.wait();

            if (is_main_worker) {
                var workers = self.getWorkers();
                while (workers.next()) |idle_worker| {
                    const thread = idle_worker.thread orelse continue;
                    idle_worker.event.set();
                    thread.wait();
                }
            }

            return .shutdown;            
        }
    }

    pub fn shutdown(self: *Scheduler) void {
        @setCold(true);
        var counter = Counter.unpack(self.counter.load(.acquire));

        while (true) {
            if (counter.state == .shutdown) {
                return;
            }

            var new_counter = counter;
            new_counter.state = .shutdown;
            if (self.counter.tryCompareAndSwap(
                counter.pack(),
                new_counter.pack(),
                .acq_rel,
                .acquire,
            )) |updated| {
                counter = Counter.unpack(updated);
                continue;
            }

            self.idleShutdown();
            return;
        }
    }

    const IDLE_EMPTY: usize = 0;
    const IDLE_NOTIFIED: usize = 1;
    const IDLE_SHUTDOWN: usize = 2;
    const IDLE_WAITING: usize = ~(IDLE_EMPTY | IDLE_NOTIFIED | IDLE_SHUTDOWN);

    fn idleWait(self: *Scheduler, worker: *Worker) void {
        @setCold(true);
        var idle_queue = self.idle_queue.load(.acquire);

        while (true) {
            if (idle_queue == IDLE_SHUTDOWN) {
                return;
            }

            if (idle_queue == IDLE_NOTIFIED) {
                idle_queue = self.idle_queue.tryCompareAndSwap(
                    idle_queue,
                    IDLE_EMPTY,
                    .acq_rel,
                    .acquire,
                ) orelse return;
                continue;
            }

            worker.idle_next = @intToPtr(?*Worker, idle_queue & IDLE_WAITING);

            idle_queue = self.idle_queue.tryCompareAndSwap(
                idle_queue,
                @ptrToInt(worker),
                .release,
                .acquire,
            ) orelse return worker.event.wait();
        }
    }

    fn idleNotify(self: *Scheduler) void {
        @setCold(true);
        var idle_queue = self.idle_queue.load(.acquire);

        while (true) {
            if (idle_queue == IDLE_SHUTDOWN) {
                return;
            }

            if (idle_queue == IDLE_NOTIFIED) {
                return;
            }

            if (idle_queue == IDLE_EMPTY) {
                idle_queue = self.idle_queue.tryCompareAndSwap(
                    idle_queue,
                    IDLE_NOTIFIED,
                    .acq_rel,
                    .acquire,
                ) orelse return;
                continue;
            }

            const worker = @intToPtr(*Worker, idle_queue & IDLE_WAITING);

            idle_queue = self.idle_queue.tryCompareAndSwap(
                idle_queue,
                @ptrToInt(worker.idle_next),
                .acq_rel,
                .acquire,
            ) orelse return worker.event.set();
        }
    }

    fn idleShutdown(self: *Scheduler) void {
        @setCold(true);
        const idle_queue = self.idle_queue.swap(IDLE_SHUTDOWN, .acq_rel);

        var idle_workers = switch (idle_queue) {
            IDLE_NOTIFIED => null,
            IDLE_SHUTDOWN => std.debug.panic("idle_queue shutdown multiple times", .{}),
            else => @intToPtr(?*Worker, idle_queue & IDLE_WAITING),
        };

        while (idle_workers) |idle_worker| {
            const worker = idle_worker;
            idle_workers = worker.idle_next;
            worker.event.set();
        }
    }
};

const UnboundedTaskQueue = struct {
    head: Atomic(usize),
    tail: Atomic(*Task),
    stub: Task,

    fn init(self: *UnboundedTaskQueue) void {
        self.head.set(@ptrToInt(&self.stub));
        self.tail.set(&self.stub);
        self.stub.next().set(null);
    }

    fn push(self: *UnboundedTaskQueue, batch: Batch) void {
        if (batch.isEmpty())
            return;

        batch.tail.next().set(null);
        const prev = self.tail.swap(batch.tail, .acq_rel);
        prev.next().store(batch.head, .release);
    }

    fn tryAcquireConsumer(self: *UnboundedTaskQueue) ?Consumer {
        const stub = &self.stub;
        var head = self.head.load(.relaxed);

        while (true) {
            if (head & 1 != 0)
                return null;
            if (self.tail.load(.relaxed) == stub)
                return null;

            head = self.head.tryCompareAndSwap(
                head,
                head | 1,
                .acquire,
                .relaxed,
            ) orelse break;
        }

        return Consumer{
            .queue = self,
            .stub = stub,
            .head = @intToPtr(*Task, head & ~@as(usize, 1)),
        };
    }

    const Consumer = struct {
        queue: *UnboundedTaskQueue,
        stub: *Task,
        head: *Task,

        fn release(self: Consumer) void {
            const new_head = @ptrToInt(self.head);
            self.queue.head.store(new_head, .release);
        }

        fn pop(self: *Consumer) ?*Task {
            var head = self.head;
            var next = head.next().load(.acquire);

            if (head == self.stub) {
                head = next orelse return null;
                self.head = head;
                next = head.next().load(.acquire);
            }

            if (next) |new_head| {
                self.head = new_head;
                return head;
            }

            const tail = self.queue.tail.load(.relaxed);
            if (head != tail) {
                return null;
            }

            self.queue.push(self.stub.toBatch());

            next = head.next().load(.acquire);
            if (next) |new_head| {
                self.head = new_head;
                return head;
            }

            return null;
        }
    };
};

const BoundedTaskQueue = struct {
    head: Atomic(usize) = Atomic(usize).init(0),
    tail: Atomic(usize) = Atomic(usize).init(0),
    buffer: [256]Atomic(*Task) = undefined,

    fn init(self: *BoundedTaskQueue) void {
        self.* = BoundedTaskQueue{};
    }

    fn push(self: *BoundedTaskQueue, tasks: Batch) ?Batch {
        var batch = tasks;
        var tail = self.tail.get();
        var head = self.head.load(.acquire);

        while (true) {
            if (batch.isEmpty())
                return null;

            const size = tail -% head;
            var open_slots = self.buffer.len - size;
            if (open_slots > 0) {

                while (open_slots > 0) : (open_slots -= 1) {
                    const task = batch.pop() orelse break;
                    self.buffer[tail % self.buffer.len].store(task, .unordered);
                    tail +%= 1;
                }

                self.tail.store(tail, .release);
                spinLoopHint();
                head = self.head.load(.acquire);
                continue;
            }

            const migrate = self.buffer.len / 2;
            const new_head = head +% migrate;
            if (self.head.tryCompareAndSwap(
                head,
                new_head,
                .acq_rel,
                .acquire,
            )) |updated| {
                head = updated;
                continue;
            }

            var overflowed = Batch{};
            while (head != new_head) : (head +%= 1) {
                const task = self.buffer[head % self.buffer.len].get();
                overflowed.push(task);
            }

            overflowed.push(batch);
            return overflowed;
        }
    }

    fn pop(self: *BoundedTaskQueue) ?*Task {
        var tail = self.tail.get();
        var head = self.head.load(.acquire);

        while (true) {
            if (tail == head)
                return null;

            const task = self.buffer[head % self.buffer.len].get();
            head = self.head.tryCompareAndSwap(
                head,
                head +% 1,
                .acq_rel,
                .acquire,
            ) orelse return task;
        }
    }

    fn popAndStealFromBounded(self: *BoundedTaskQueue, target: *BoundedTaskQueue) ?*Task {
        if (target == self)
            return self.pop();

        const tail = self.tail.get();
        const head = self.head.load(.acquire);
        if (tail != head)
            return self.pop();

        var target_head = target.head.load(.acquire);
        while (true) {
            const target_tail = target.tail.load(.acquire);
            const target_size = target_tail -% target_head;
            if (target_size == 0)
                return null;

            var steal = target_size - (target_size / 2);
            if (steal > target.buffer.len / 2) {
                spinLoopHint();
                target_head = target.head.load(.acquire);
                continue;
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
                .acq_rel,
                .acquire,
            )) |updated| {
                target_head = updated;
                continue;
            }

            if (new_tail != tail)
                self.tail.store(new_tail, .release);
            return first_task;
        }
    }

    fn popAndStealFromUnbounded(self: *BoundedTaskQueue, target: *UnboundedTaskQueue) ?*Task {
        var consumer = target.tryAcquireConsumer() orelse return null;
        defer consumer.release();

        const first_task = consumer.pop() orelse return null;
        const head = self.head.load(.acquire);
        const tail = self.tail.get();

        var new_tail = tail;
        while (new_tail -% head < self.buffer.len) {
            const task = consumer.pop() orelse break;
            self.buffer[new_tail % self.buffer.len].store(task, .unordered);
            new_tail +%= 1;
        }

        if (new_tail != tail)
            self.tail.store(new_tail, .release);
        return first_task;
    }
};

