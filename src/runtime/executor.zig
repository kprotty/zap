const std = @import("std");
const Semaphore = @import("./semaphore.zig").Semaphore;

pub const Task = struct {
    next: ?*Task = undefined,
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
            return (blk: {
                @setRuntimeSafety(false);
                break :blk @intToPtr(Callback, self.runnable & ~@as(usize, 1));
            })(self);
        }

        resume blk: {
            @setRuntimeSafety(false);
            break :blk @intToPtr(anyframe, self.runnable);
        };
    }

    pub fn toBatch(self: *Task) Batch {
        return Batch.from(self);
    }
};

pub const Batch = struct {
    head: ?*Task = null,
    tail: *Task = undefined,

    pub fn from(batchable: anytype) Batch {
        if (@TypeOf(batchable) == Batch)
            return batchable;

        if (@TypeOf(batchable) == *Task) {
            batchable.next = null;
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
            self.tail.next = other.head;
            self.tail = other.tail;
        }
    }

    pub fn pushFront(self: *Batch, entity: anytype) void {
        const other = Batch.from(entity);
        if (self.isEmpty()) {
            self.* = other;
        } else {
            other.tail.next = self.head;
            self.head = other.head;
        }
    }

    pub fn pop(self: *Batch) ?*Task {
        return self.popFront();
    }

    pub fn popFront(self: *Batch) ?*Task {
        const task = self.head orelse return null;
        self.head = task.next;
        return task;
    }
};

pub const Worker = struct {
    join_event: std.AutoResetEvent = std.AutoResetEvent{},
    run_queue_overflow: UnboundedTaskQueue = undefined,
    run_queue: BoundedTaskQueue = undefined,
    next: ?*Worker = null,
    scheduler: *Scheduler,
    thread: ?*std.Thread,

    threadlocal var tls_current: ?*Worker = null;

    fn spawn(scheduler: *Scheduler) !void {
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
        spawner.thread = try std.Thread.spawn(&spawner, Spawner.entry);
        spawner.thread_event.set();
        spawner.spawn_event.wait();
    }

    fn run(scheduler: *Scheduler, thread: ?*std.Thread) void {
        var self = Worker{ .scheduler = scheduler, .thread = thread };
        self.run_queue_overflow.init();
        self.run_queue.init();

        const old_tls_current = tls_current;
        tls_current = &self;
        defer tls_current = old_tls_current;

        var active_queue = @atomicLoad(?*Worker, &scheduler.active_queue, .Monotonic);
        while (true) {
            self.next = active_queue;
            active_queue = @cmpxchgWeak(
                ?*Worker,
                &scheduler.active_queue,
                active_queue,
                &self,
                .Release,
                .Monotonic,
            ) orelse break;
        }

        var worker_iter = scheduler.getWorkers();
        var run_tick = @ptrToInt(&self) ^ @ptrToInt(scheduler);
        while (true) {
            if (self.poll(scheduler, run_tick, &worker_iter)) |task| {
                run_tick +%= 1;
                task.execute();
                continue;
            }

            if (@atomicLoad(bool, &scheduler.is_shutdown, .Acquire)) {
                break;
            } else {
                scheduler.idle_queue.wait();
            }
        }

        scheduler.endWorker();

        if (self.thread == null) {
            scheduler.join();
        } else {
            self.join_event.wait();
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

        if (self.run_queue.pop()) |task| {
            return task;
        }

        if (self.run_queue.popAndStealFromUnbounded(&self.run_queue_overflow)) |task| {
            return task;
        }

        if (self.run_queue.popAndStealFromUnbounded(&scheduler.run_queue)) |task| {
            return task;
        }

        var num_workers = @atomicLoad(usize, &scheduler.num_workers, .Monotonic);
        while (num_workers > 0) : (num_workers -= 1) {
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

    pub fn schedule(self: *Worker, batch: Batch) void {
        if (batch.isEmpty())
            return;

        if (self.run_queue.push(batch)) |overflowed|
            self.run_queue_overflow.push(overflowed);

        const scheduler = self.scheduler;
        scheduler.idle_queue.notify(1);
    }
};

pub const Scheduler = struct {
    is_shutdown: bool = false,
    idle_queue: Semaphore = Semaphore{},
    active_queue: ?*Worker = null,
    run_queue: UnboundedTaskQueue = undefined,
    join_event: std.AutoResetEvent = std.AutoResetEvent{},
    num_workers: usize = 0,

    pub const RunConfig = struct {
        threads: ?usize = null,
    };

    pub fn run(config: RunConfig, batch: Batch) !void {
        if (batch.isEmpty())
            return;

        const threads = (
            if (std.builtin.single_threaded) 
                @as(usize, 1)
            else if (config.threads) |threads|
                std.math.max(1, threads)
            else 
                std.Thread.cpuCount() catch 1
        );

        var self = Scheduler{};
        self.run_queue.init();
        self.run_queue.push(batch);

        var extra_threads = threads - 1;
        while (extra_threads > 1) : (extra_threads -= 1) {
            self.beginWorker();
            Worker.spawn(&self) catch |err| {
                self.endWorker();
                self.join();
                return err;
            };
        }

        self.beginWorker();
        Worker.run(&self, null);
    }

    pub fn getWorkers(self: *Scheduler) WorkerIter {
        const active_worker = @atomicLoad(?*Worker, &self.active_queue, .Acquire);
        return WorkerIter{ .worker = active_worker };
    }

    pub const WorkerIter = struct {
        worker: ?*Worker,

        pub fn next(self: *WorkerIter) ?*Worker {
            const worker = self.worker orelse return null;
            self.worker = worker.next;
            return worker;
        }
    };

    pub fn schedule(self: *Scheduler, batch: Batch) void {
        self.run_queue.push(batch);
        self.idle_queue.notify(1);
    }

    pub fn shutdown(self: *Scheduler) void {
        const num_workers = @atomicLoad(usize, &self.num_workers, .SeqCst); 
        @atomicStore(bool, &self.is_shutdown, true, .Release);
        self.idle_queue.notify(num_workers);
    }

    fn beginWorker(self: *Scheduler) void {
        _ = @atomicRmw(usize, &self.num_workers, .Add, 1, .SeqCst);
    }

    fn endWorker(self: *Scheduler) void {
        if (@atomicRmw(usize, &self.num_workers, .Sub, 1, .SeqCst) == 1)
            self.join_event.set();
    }

    fn join(self: *Scheduler) void {
        self.join_event.wait();

        var workers = self.getWorkers();
        while (workers.next()) |idle_worker| {
            const idle_thread = idle_worker.thread orelse continue;
            idle_worker.join_event.set();
            idle_thread.wait();
        }
    }
};

const UnboundedTaskQueue = struct {
    head: usize,
    tail: *Task,
    stub: Task,

    fn init(self: *UnboundedTaskQueue) void {
        self.head = @ptrToInt(&self.stub);
        self.tail = &self.stub;
        self.stub.next = null;
    }

    fn push(self: *UnboundedTaskQueue, batch: Batch) void {
        if (batch.isEmpty())
            return;

        batch.tail.next = null;
        const prev = @atomicRmw(*Task, &self.tail, .Xchg, batch.tail, .AcqRel);
        @atomicStore(?*Task, &prev.next, batch.head, .Release);
    }

    fn tryAcquireConsumer(self: *UnboundedTaskQueue) ?Consumer {
        const stub = &self.stub;
        var head = @atomicLoad(usize, &self.head, .Monotonic);

        while (true) {
            if (head & 1 != 0)
                return null;
            if (@atomicLoad(*Task, &self.tail, .Monotonic) == stub)
                return null;

            head = @cmpxchgWeak(
                usize,
                &self.head,
                head,
                head | 1,
                .Acquire,
                .Monotonic,
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
            const head = @ptrToInt(self.head);
            @atomicStore(usize, &self.queue.head, head, .Release);
        }

        fn pop(self: *Consumer) ?*Task {
            var head = self.head;
            var next = @atomicLoad(?*Task, &head.next, .Acquire);

            if (head == self.stub) {
                head = next orelse return null;
                self.head = head;
                next = @atomicLoad(?*Task, &head.next, .Acquire);
            }

            if (next) |new_head| {
                self.head = new_head;
                return head;
            }

            const tail = @atomicLoad(*Task, &self.queue.tail, .Monotonic);
            if (head != tail) {
                return null;
            }

            self.queue.push(self.stub.toBatch());

            next = @atomicLoad(?*Task, &head.next, .Acquire);
            if (next) |new_head| {
                self.head = new_head;
                return head;
            }

            return null;
        }
    };
};

const BoundedTaskQueue = struct {
    head: usize = 0,
    tail: usize = 0,
    buffer: [256]*Task = undefined,

    fn init(self: *BoundedTaskQueue) void {
        self.* = BoundedTaskQueue{};
    }

    fn push(self: *BoundedTaskQueue, tasks: Batch) ?Batch {
        var batch = tasks;
        var tail = self.tail;
        var head = @atomicLoad(usize, &self.head, .Acquire);

        while (true) {
            if (batch.isEmpty())
                return null;

            const size = tail -% head;
            var open_slots = self.buffer.len - size;
            if (open_slots > 0) {

                while (open_slots > 0) : (open_slots -= 1) {
                    const task = batch.pop() orelse break;
                    @atomicStore(*Task, &self.buffer[tail % self.buffer.len], task, .Unordered);
                    tail +%= 1;
                }

                @atomicStore(usize, &self.tail, tail, .Release);
                std.SpinLock.loopHint(1);
                head = @atomicLoad(usize, &self.head, .Acquire);
                continue;
            }

            const migrate = self.buffer.len / 2;
            const new_head = head +% migrate;
            if (@cmpxchgWeak(
                usize,
                &self.head,
                head,
                new_head,
                .AcqRel,
                .Acquire,
            )) |updated| {
                head = updated;
                continue;
            }

            var overflowed = Batch{};
            while (head != new_head) : (head +%= 1) {
                const task = self.buffer[head % self.buffer.len];
                overflowed.push(task);
            }

            overflowed.push(batch);
            return overflowed;
        }
    }

    fn pop(self: *BoundedTaskQueue) ?*Task {
        var tail = self.tail;
        var head = @atomicLoad(usize, &self.head, .Acquire);

        while (true) {
            if (tail == head)
                return null;

            const task = self.buffer[head % self.buffer.len];
            head = @cmpxchgWeak(
                usize,
                &self.head,
                head,
                head +% 1,
                .AcqRel,
                .Acquire,
            ) orelse return task;
        }
    }

    fn popAndStealFromBounded(self: *BoundedTaskQueue, target: *BoundedTaskQueue) ?*Task {
        if (target == self)
            return self.pop();

        const tail = self.tail;
        const head = @atomicLoad(usize, &self.head, .Acquire);
        if (tail != head)
            return self.pop();

        var target_head = @atomicLoad(usize, &target.head, .Acquire);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.tail, .Acquire);
            const target_size = target_tail -% target_head;
            if (target_size == 0)
                return null;

            var steal = target_size - (target_size / 2);
            if (steal > target.buffer.len / 2) {
                std.SpinLock.loopHint(1);
                target_head = @atomicLoad(usize, &target.head, .Acquire);
                continue;
            }

            const first_task = @atomicLoad(*Task, &target.buffer[target_head % target.buffer.len], .Unordered);
            var new_target_head = target_head +% 1;
            var new_tail = tail;
            steal -= 1;

            while (steal > 0) : (steal -= 1) {
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
                .AcqRel,
                .Acquire,
            )) |updated| {
                target_head = updated;
                continue;
            }

            if (new_tail != tail)
                @atomicStore(usize, &self.tail, new_tail, .Release);
            return first_task;
        }
    }

    fn popAndStealFromUnbounded(self: *BoundedTaskQueue, target: *UnboundedTaskQueue) ?*Task {
        var consumer = target.tryAcquireConsumer() orelse return null;
        defer consumer.release();

        const first_task = consumer.pop() orelse return null;
        const head = @atomicLoad(usize, &self.head, .Monotonic);
        const tail = self.tail;

        var new_tail = tail;
        while (new_tail -% head < self.buffer.len) {
            const task = consumer.pop() orelse break;
            @atomicStore(*Task, &self.buffer[new_tail % self.buffer.len], task, .Unordered);
            new_tail +%= 1;
        }

        if (new_tail != tail)
            @atomicStore(usize, &self.tail, new_tail, .Release);
        return first_task;
    }
};

