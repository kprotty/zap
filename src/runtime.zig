const std = @import("std");
const is_debug = std.debug.runtime_safety;
const is_single_threaded = std.builtin.single_threaded;

const Runtime = @This();

async_scheduler: Scheduler,
blocking_scheduler: if (is_single_threaded) void else Scheduler,

fn ReturnTypeOf(comptime asyncFn: anytype) type {
    return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
}

///////////////////////////////////////////////////////////////////////
// Generic Runtime API
///////////////////////////////////////////////////////////////////////

pub const Config = struct {
    async_pool: Pool = Pool{
        .threads = null,
        .stack_size = 16 * 1024 * 1024,
    },
    blocking_pool: Pool = Pool{
        .threads = 64,
        .stack_size = 1 * 1024 * 1024,
    },

    pub const Pool = struct {
        threads: ?u16,
        stack_size: usize,
    };

    pub fn run(self: Config, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        return self.runWithShutdown(true, asyncFn, args);
    }

    pub fn runForever(self: Config, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        return self.runWithShutdown(false, asyncFn, args);

    fn runWithShutdown(self: Config, shutdown_after: bool, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        const Decorator = struct {
            fn entry(task: *Task, result: *?ReturnTypeOf(asyncFn), shutdown: bool, asyncArgs: @TypeOf(args)) void {
                suspend task.* = Task.init(@frame());
                const return_value = @call(.{}, asyncFn, asyncArgs);
                suspend {
                    result.* = return_value;
                    if (shutdown) {
                        Worker.getCurrent().getScheduler().shutdown();
                    }
                }
            }
        };

        var task: Task = undefined;
        var result: ?ReturnTypeOf(asyncFn) = null;
        var frame = async Decorator.entry(&task, &result, shutdown_after, args);


    }
};

pub fn getAllocator() *Allocator {
    return Worker.getCurrent().getAllocator();
}

pub fn runConcurrently() void {
    suspend {
        var task = Task.init(@frame());
        Worker.getCurrent().schedule(&task, .{ .use_lifo = true });
    }
}

pub fn spawn(allocator: *Allocator, comptime asyncFn: anytype, args: anytype) error{OutOfMemory}!void {
    if (ReturnTypeOf(asyncFn) != void) {
        @compileError("the return type of a spawned function must be void");
    }

    const Decorator = struct {
        fn entry(frame_allocator: *Allocator, asyncArgs: @TypeOf(args)) void {
            runConcurrently();
            @call(.{}, asyncFn, asyncArgs);
            suspend frame_allocator.destroy(@frame());
        }
    };

    const frame = try allocator.create(@Frame(Decorator.entry));
    frame.* = async Decorator.entry(allocator, args);
}

pub fn yield() void {
    suspend {
        var task = Task.init(@frame());
        Worker.getCurrent().schedule(&task, .{});
    }
}

pub fn callBlocking(comptime asyncFn: anytype, args: anytype) ReturnTypeOf(asyncFn) {
    if (is_single_threaded)
        return @call(.{}, asyncFn, args);

    const scheduler = Worker.getCurrent().getScheduler();
    const blocking_scheduler = scheduler.getRuntime().blocking_scheduler;

    if (scheduler != blocking_scheduler) {
        suspend {
            var task = Task.init(@frame());
            blocking_scheduler.schedule(Batch.from(&task));
        }
    }

    defer if (scheduler != blocking_scheduler) {
        suspend {
            var task = Task.init(@frame());
            scheduler.schedule(Batch.from(&task));
        }
    };

    return @call(.{}, asyncFn, args);
}

///////////////////////////////////////////////////////////////////////
// Customizable Runtime API
///////////////////////////////////////////////////////////////////////

pub const Task = struct {
    next: ?*Task = undefined,
    runnable: usize,

    pub fn init(frame: anyframe) Task {
        if (@alignOf(anyframe) < 2)
            @compileError("anyframe does not meet the minimum alignment requirement");
        return Task{ .runnable = @ptrToInt(frame) };
    }

    pub const Callback = fn(*Task, *Worker) callconv(.C) void;

    pub fn initCallback(callback: Callback) Task {
        if (@alignOf(Callback) < 2)
            @compileError("Callback does not meet the minimum alignment requirement");
        return Task{ .runnable = @ptrToInt(callback) | 1 };
    }

    pub fn execute(self: *Task, worker: *Worker) void {
        @setRuntimeSafety(false);

        const runnable = self.runnable;
        if (runnable & 1 != 0) {
            const callback = @intToPtr(Callback, runnable & ~@as(usize, 1));
            return (callback)(self, worker);
        }

        const frame = @intToPtr(anyframe, runnable);
        resume frame;
    }
};

pub const Batch = struct {
    head: ?*Task = null,
    tail: *Task = undefined,

    pub fn from(entity: anytype) Batch {
        if (@TypeOf(entity) == Batch)
            return entity;

        if (@TypeOf(entity) == *Task) {
            entity.next = null;
            return Batch{
                .head = entity,
                .tail = entity,
            };
        }

        if (@TypeOf(entity) == ?*Task) {
            const task: *Task = entity orelse return Batch{};
            return Batch.from(task);
        }

        return @compileError(@typeName(@TypeOf(entity)) ++ " cannot be converted into a " ++ @typeName(Batch));
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
    idle_node: IdleQueue.Node = IdleQueue.Node{},
    active_node: ActiveQueue.Node = ActiveQueue.Node{},
    run_queue: BoundedQueue = BoundedQueue{},
    run_queue_next: ?*Task = null,
    run_queue_lifo: ?*Task = null,
    run_queue_overflow: UnboundedQueue = undefined,
    scheduler: *Scheduler,
    thread: ?*OsThread = undefined,
    futex: OsFutex,

    threadlocal var tls_current: ?*Worker = null;

    fn run(scheduler: *Scheduler) void {
        // Allocate the worker on the OS Thread's stack
        var self: Worker = undefined;
        self.* = Worker{ .scheduler = scheduler };
        self.thread = OsThread.getSpawned();
        self.run_queue_overflow.init();

        self.futex.init();
        defer self.futex.deinit();

        // register the thread onto the Scheduler
        scheduler.active_queue.push(&self.active_node);
        
        // Set the TLS worker pointer while restoring it on exit to allow for nested Worker.run() calls.
        const old_tls_current = tls_current;
        tls_current = &self;
        defer tls_current = old_tls_current;

        var is_resuming = true;
        var run_queue_tick = @ptrToInt(self) ^ @ptrToInt(scheduler);
        var worker_iter = scheduler.getWorkers();

        while (true) {
            // Search for any runnable tasks in the scheduler
            if (self.poll(scheduler, run_queue_tick, &worker_iter)) |task| {
                // If we find a task while resuming, we try to resume another worker.
                // This results in a handoff-esque thread wakup mechanism instead of thundering-herd waking scenarios.
                if (is_resuming) {
                    is_resuming = false;
                    _ = scheduler.tryResumeWorker(true);
                }

                task.execute(self);
                run_queue_tick +%= 1;
                continue;
            }

            // No tasks were found in the scheduler, try to put this worker/thread to sleep
            is_resuming = switch (scheduler.suspendWorker(&self, is_resuming)) {
                .retry => false,
                .resumed => true,
                .shutdown => break,
            };
        }
    }

    /// Gets a refereence to the currently running Worker, panicking if called outside of a Worker thread.
    /// This exists primarily due to the inability for async frames to take resume parameters (for the *Worker).
    pub fn getCurrent() *Worker {
        return tls_current orelse {
            std.debug.panic("Worker.getCurrent() called outside of the runtime", .{})
        };
    }

    /// Gets a reference to the Scheduler which this worker is apart of.
    pub fn getScheduler(self: *Worker) *Scheduler {
        return self.scheduler;
    }

    pub const ScheduleHints = struct {
        use_next: bool = false,
        use_lifo: bool = false,
    };

    /// Mark a batch of tasks as runnable which will eventually be executed on some Worker in the Scheduler.
    pub fn schedule(self: *Worker, entity: anytype, hints: ScheduleHints) void {
        var batch = Batch.from(entity);
        if (batch.isEmpty()) {
            return;
        }

        // Use the "next" slot when available, pushing the old entry out.
        // This exits earlier if theres nothing else to schedule as 
        //  a new "next" task shouldn't do resumeWorker() since other workers cant even steal it.
        if (hints.use_next) {
            const old_next = self.run_queue_next;
            self.run_queue_next = batch.popFront();
            if (old_next) |next| {
                batch.pushFront(next);
            }
            if (batch.isEmpty()) {
                return;
            }
        }

        // Use the "LIFO" slot when available as well, pushing the old entry out too.
        if (hints.use_lifo) {
            if (@atomicRmw(?*Task, &self.run_queue_lifo, .Xchg, batch.popFront(), .AcqRel)) |old_lifo| {
                batch.pushFront(old_lifo);
            }
        }

        // Push any remaining tasks to the local run queue, which overflows into the overflow queue when full.
        if (!batch.isEmpty()) {
            if (self.run_queue.push(batch)) |overflowed| {
                self.run_queue_overflow.push(overflowed);
            }
        }

        // Finally, try to wake up a worker to handle these newly enqueued tasks
        const scheduler = self.getScheduler();
        _ = scheduler.tryResumeWorker(false);
    }

    /// Tries to find a runnable task in the system/scheduler the worker is apart of and dequeues it from it's run queue.
    fn poll(self: *Worker, scheduler: *Scheduler, run_queue_tick: usize, workers: *Scheduler.WorkerIter) ?*Task {
        // TODO: if single_threaded, poll for io and timer resources here
        
        // every once in a while, check the scheduler's run queue for eventual fairness
        if (run_queue_tick % 61 == 0) {
            if (self.run_queue.popAndStealUnbounded(&scheduler.run_queue)) |task| {
                return task;
            }
        }

        // every once in a while (more frequency), check our Worker's overflow task queue for eventual fairness
        if (run_queue_tick % 31 == 0) {
            if (self.run_queue.popAndStealUnbounded(&self.run_queue_overflow)) |task| {
                return task;
            }
        }

        // first check our "next" slot as it acts like an un-stealable LIFO slot
        if (self.run_queue_next) |next_task| {
            const task = next_task;
            self.run_queue_next = null;
            return task;
        }

        // next, check our "LIFO" slot as its used to gain priority over other tasks but is also work-stealable.
        if (@atomicLoad(?*Task, &self.run_queue_lifo, .Monotonic) != null) {
            if (@atomicRmw(?*Task, &self.run_queue_lifo, .Xchg, null, .Acquire)) |lifo_task| {
                return lifo_task;
            }
        }

        // our local run queue serves as the primary place we go to look for tasks.
        if (self.run_queue.pop()) |task| {
            return task;
        }

        // If our local run queue is empty, check our local overflow queue instead.
        // All stealing operations have the ability to populate our local run queue for next time.
        if (self.run_queue.popAndStealUnbounded(&self.run_queue_overflow)) |task| {
            return task;
        }

        // If we have no tasks locally at all, check the global/scheduler run queue for tasks.
        if (self.run_queue.popAndStealUnbounded(&scheduler.run_queue)) |task| {
            return task;
        }

        // No tasks were found locally and globally/on-the-scheduler.
        // We now need to resort to work-stealing.
        //
        // Find out how many workers there are active in the scheduler.
        var running_workers = blk: {
            const count = @atomicLoad(u32, &scheduler.counter, .Monotonic);
            const counter = Scheduler.Counter.unpack(count);
            break :blk counter.spawned;
        };

        // Iterate through the running workers in the scheduler to try and steal tasks.
        while (running_workers > 0) : (running_workers -= 1) {
            const target_worker = workers.next() orelse blk: {
                workers.* = scheduler.getWorkers();
                break :blk workers.next() orelse std.debug.panic("No workers found when work-stealing");
            };

            // No point in stealing tasks from ourselves
            if (target_worker == self) {
                continue;
            }

            // Try to steal tasks directly from the target's local run queue to our local run queue
            if (self.run_queue.popAndStealBounded(&target_worker.run_queue)) |task| {
                return task;
            }

            // If that fails, look for tasks in the target's overflow queue
            if (self.run_queue.popAndStealUnbounded(&target_worker.run_queue_overflow)) |task| {
                return task;
            }

            // If even that fails, then as a really last resort, try to steal the target's LIFO task
            if (@atomicLoad(?*Task, &target_worker.run_queue_lifo, .Monotonic) != null) {
                if (@atomicRmw(?*Task, &target_worker.run_queue_lifo, .Xchg, null, .Acquire)) |lifo_task| {
                    return lifo_task;
                }
            }
        }

        // Despite all our searching, no work/tasks seems to be available in the system/scheduler.
        return null;
    }
};

pub const Scheduler = struct {
    is_blocking: bool,
    run_queue: UnboundedQueue,
    idle_queue: IdleQueue = IdleQueue{},
    active_queue: ActiveQueue = ActiveQueue{},
    counter: u32 = (Counter{}).pack(),
    max_workers: u16,
    main_worker: ?*Worker = null,

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

    /// Get a reference to the Runtime this Scheduler is apart of
    pub fn getRuntime(self: *Scheduler) *Runtime {
        if (self.is_blocking)
            return @fieldParentPtr(Runtime, "blocking_scheduler", self);
        return @fieldParentPtr(Runtime, "async_scheduler", self);
    }

    /// Get an iterator which can be used to discover all worker's reachable from the Scheduler at the time of calling.
    pub fn getWorkers(self: *Scheduler) WorkerIter {
        return WorkerIter{ .iter = self.active_queue.iter() };
    }

    pub const WorkerIter = struct {
        iter: ActiveQueue.Iter,

        pub fn next(self: *WorkerIter) ?*Worker {
            const node = self.iter.next() orelse return null;
            return @fieldParentPtr(Worker, "active_node", node); 
        }
    };

    /// Enqueue a batch of tasks into the scheduler and try to resume a worker in order to handle them.
    pub fn schedule(self: *Scheduler, entity: anytype) void {
        const batch = Batch.from(entity);
        if (batch.isEmpty()) {
            return;
        }

        self.run_queue.push(batch);
        _ = self.tryResumeWorker(false);
    }

    /// Try to wake up or start a Worker thread in order to poll for tasks.
    fn tryResumeWorker(self: *Scheduler, is_caller_resuming: bool) bool {
        // We only need to load the max-worker value once as it never changes.
        const max_workers = self.max_workers;

        // Bound the amount of times we retry resuming a worker to prevent live-locks when scheduling is busy.
        var remaining_attempts: u8 = 3;
        var is_resuming = is_caller_resuming;
        var counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));

        while (true) {
            if (counter.state == .shutdown) {
                return false;
            }
            
            // Try to resume a pending worker if theres pending workers in the idle queue or if theres unspawned workers.
            const has_resumables = (counter.idle > 0 or counter.spawned < max_workers);

            // In addition, it should only attempt the resume if:
            //  - it was the one who set the state to .resumed (is_resuming) and it hasn't failed to resume too many times
            //  - its a normal caller who wishes to resume a worker and sees that there isn't currently a resume/notification in progress.
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

                if (@cmpxchgWeak(
                    u32,
                    &self.counter,
                    counter.pack(),
                    new_counter.pack(),
                    .Monotonic,
                    .Monotonic,
                )) |updated| {
                    counter = Counter.unpack(updated);
                    continue;
                } else {
                    is_resuming = true;
                }

                // Notify an idle worker if there is one
                if (counter.idle > 0) {
                    switch (self.idle_queue.notify()) {
                        .notified, .shutdown => return,
                        .resumed => |idle_node| {
                            const worker = @fieldParentPtr(Worker, "idle_node", idle_node);
                            worker.futex.wake();
                            return true;
                        },
                    };
                }

                // If this is the first worker thread, use the caller's Thread (the main thread is also a Worker)
                if (is_single_threaded or counter.spawned == 0) {
                    Worker.run(self);
                    return true;
                }

                // Try to spawn an OS thread for the resuming worker
                if (OsThread.spawn(.{}, Worker.run, .{self})) |_| {
                    return true;
                } else |spawn_err| {}

                // We failed to resume a worker after setting the counter state to .resume, loop back to handle this.
                spinLoopHint();
                remaining_attempts -= 1;
                counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));
                continue;
            }

            // We werent able to resume a possible pending worker.
            // Try to update the state to either leave a notification that we tried to resume or unset the .resuming state if we failed to.
            // Returns if theres already a notification of some kind, as then theres nothing left to do.
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
            if (@cmpxchgWeak(
                u32,
                &self.counter,
                counter.pack(),
                new_counter.pack(),
                .Monotonic,
                .Monotonic,
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

    const SuspendCondition = struct {
        result: ?Suspend,
        scheduler: *Scheduler,
        worker: *Worker,
        is_resuming: bool,
        is_main_worker: bool,

        fn poll(condition: *Condition) bool {
            const self = condition.scheduler;
            const worker = condition.worker;
            const max_workers = self.max_workers;
            const is_resuming = condition.is_resuming;

            var counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));
            while (true) {

                const has_resumables = counter.idle > 0 or counter.spawned < max_workers;
                const is_shutdown = counter.state == .shutdown;
                const is_notified = switch (counter.state) {
                    .resumer_notified => is_resuming,
                    .suspend_notified => true,
                    else => false,
                };

                // If we're about to suspend and someone left a notification for us in tryResumeWorker(), then consume it and don't suspend.
                // This also deregisters ourselves from the counter if we're shutting down which is used to synchronize the scheduler joining all threads.
                var new_counter = counter;
                if (is_shutdown) {
                    new_counter.spawned -= 1;
                } else if (is_notified) {
                    new_counter.state = if (is_resuming) .resuming else .pending;
                } else {
                    new_counter.state = if (has_resumables) .pending else .suspend_notified;
                    new_counter.idle += 1;
                }

                // Set the main worker on the scheduler before updating the counter.
                // After the update, and if we're the last to shutdown, we may end up reading it.
                if (condition.is_main_worker) {
                    scheduler.main_worker = worker;
                }

                // Acquire barrier to make sure any main_worker reads aren't reordered before we mark ourselves as shutdown as it may not exist yet.
                // Release barrier to make sure the main_worker exists for the last worker to mark itself as shutdown below.
                if (@cmpxchgWeak(
                    u32,
                    &self.counter,
                    counter.pack(),
                    new_counter.pack(),
                    .AcqRel,
                    .Monotonic,
                )) |updated| {
                    counter = Counter.unpack(updated);
                    continue;
                }

                if (is_notified and is_resuming) {
                    condition.result = Suspend.resumed;
                } else if (is_notified) {
                    condition.result = Suspend.retry;
                } else if (is_shutdown) {
                    condition.result = Suspend.shutdown;
                } else {
                    condition.result = null;
                }

                // If we're the last worker to mark ourselves as shutdown, then notify the main_worker to clean everyone up.
                // If we *are* the main_worker, then we just dont suspend by returning true for the wait condition.
                if (is_shutdown and counter.spawned == 0) {
                    if (scheduler.main_worker) |main_worker| {
                        if (worker == main_worker) {
                            return true;
                        } else {
                            main_worker.futex.wake();
                        }
                    } else {
                        std.debug.panic("Scheduler shutting down without a main worker", .{});
                    }
                }

                return is_notified;
            }
        }
    };

    fn suspendWorker(self: *Scheduler, worker: *Worker, is_caller_resuming: bool) Suspend {
        // The main worker is the one without a thread (e.g. the one running on the main thread)
        const is_main_worker = worker.thread == null;

        var condition = SuspendCondition{
            .result = undefined,
            .scheduler = self,
            .worker = worker,
            .is_resuming = is_caller_resuming,
            .is_main_worker = is_main_worker,
        };

        // Wait on the worker's futex using the Suspend condition
        worker.futex.wait(&condition);

        // Get the result of the suspend condition or, if the Thread was woken up, assume its now resuming.
        const result = condition.result orelse return .resumed;
        
        // If the main worker was resumed for a shutdown, then it has to wake up everyone else and join/free their OS thread.
        if (result == .shutdown and is_main_worker) {
            var workers = self.getWorkers();
            while (workers.next()) |idle_worker| {
                const thread = idle_worker.thread orelse continue;
                idle_worker.futex.wake();
                thread.join();
            }
        }

        return result;
    }

    /// Mark the scheduler as shutdown
    pub fn shutdown(self: *Scheduler) void {
        var counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));

        while (true) {
            // if the Scheduler is already shutdown then theres nothing to be done
            if (counter.state == .shutdown) {
                return;
            }

            // Transition the scheduler into a shutdown state, stopping future Workers from being woken up and eventually stopping the Scheduler.
            // Acquire barrier to make sure any shutdown writes below don't get reordered before we mark the counter as shutdown.
            var new_counter = counter;
            new_counter.state = .shutdown;
            if (@cmpxchgWeak(
                u32,
                &self.counter,
                counter.pack(),
                new_counter.pack(),
                .Acquire,
                .Monotonic,
            )) |updated| {
                counter = Counter.pack(updated);
                continue;
            }

            // We marked the counter as shutdown, so no more workers will be doing into the idle_queue.
            // Now we wake up every worker in the idle_queue so they can observe the shutdown and stop/join on the Scheduler.
            var idle_nodes = self.idle_queue.shutdown();
            while (idle_nodes.next()) |idle_node| {
                const idle_worker = @fieldParentPtr(Worker, "idle_node", idle_node);
                idle_worker.futex.wake();
            }

            return;
        }
    }
};

///////////////////////////////////////////////////////////////////////
// Internal Runtime API
///////////////////////////////////////////////////////////////////////

/// An unbounded, Multi-Producer-Single-Consumer (MPSC) queue of Tasks.
/// This is based on Dmitry Vyukov's Intrusive MPSC with a lock-free guard:
/// http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
const UnboundedQueue = struct {
    has_consumer: bool,
    head: *Task,
    tail: *Task,
    stub: Task,

    /// Initialize the UnboundedQueue, using the self-referential stub Task as a starting point.
    fn init(self: *UnboundedQueue) void {
        self.has_consumer = false;
        self.head = &self.stub;
        self.tail = &self.stub;
        self.stub.next = null;
    }

    /// Returns true if the UnboundedQueue is observed to be pseudo-empty
    fn isEmpty(self: *const UnboundedQueue) bool {
        const tail = @atomicLoad(*Task, &self.tail, .Monotonic);
        return tail == &self.stub;
    }

    /// Pushes a batch of tasks to the UnboundedQueue in a wait-free manner.
    fn push(self: *UnboundedQueue, entity: anytype) void {
        const batch = Batch.from(entity);
        if (batch.isEmpty()) {
            return;
        }

        // Push our end of the batch to the end of the queue.
        // Acquire barrier as we will be dereferencing the previous tail.
        // Release barrier to publish the batch's task writes to other threads.
        batch.tail.next = null;
        const prev = @atomicRmw(*Task, &self.tail, .Xchg, batch.tail, .AcqRel);

        // (*) Before this store, the queue is in an inconsistent state.
        // It has a new tail, but it and the batch's tasks aren't reachable from the head of the queue yet.
        // This means that the consumer could incorrectly see an empty queue during this time.
        //
        // This is OK as when we push to UnboundedQueue's, we generally wake up another thread to pop from it.
        // Meaning that even if the consumer seems an incorrectly empty queue, it will be waken up again to see the tasks in full eventually.

        // Release barrier to ensure the batch writes above are visible on the consumer's side when loading the .next with Acquire.
        // This also fixes the queue from the inconsistent state so that the consumer has access to the batch of tasks we just pushed.
        @atomicStore(?*Task, &prev.next, batch.head, .Release);
    }

    /// Try to acquire ownership of the consumer-side of the queue in order to dequeue tasks.
    fn tryAcquireConsumer(self: *UnboundedQueue) ?Consumer {
        // No point in consuming anything if theres nothing to consume
        if (self.isEmpty()) {
            return null;
        }
        
        // Do a preemptive check to see if theres already a consumer to avoid the synchronization cost below.
        if (@atomicLoad(bool, &self.has_consumer, .Monotonic)) {
            return null;
        }

        // Try to grab the ownership rights of the consuming side of the queue.
        // Acquire barrier to ensure we read correct `self.head` updated from the previous consumer.
        if (@atomicRmw(bool, &self.has_consumer, .Xchg, true, .Acquire)) {
            return null;
        }

        return Consumer{
            .queue = self,
            .head = self.head,
            .stub = &self.stub,
        };
    }

    /// An instance of ownership on the consuming side of the UnboundedQueue.
    /// Given the queue is Single-Consumer, only one thread can be dequeueing tasks from it at a time.
    const Consumer = struct {
        queue: *UnboundedQueue,
        head: *Task,
        stub: *Task,

        /// Release ownership of the consuming side of the UnboundedQueue so other threads can start consuming.
        fn release(self: Consumer) void {
            self.queue.head = self.head;

            // Release barrier to ensure the next consumer reads our valid update to self.queue.head.
            @atomicStore(bool, &self.queue.has_consumer, false, .Release);
        }

        fn pop(self: *Consumer) ?*Task {
            var head = self.head;
            var next = @atomicLoad(?*Task, &head.next, .Acquire);

            // Try to skip the stub node if its at the head of our queue snapshot
            if (head == self.stub) {
                head = next orelse return null;
                self.head = head;
                next = @atomicLoad(?*Task, &head.next, .Acquire);
            }

            // If theres another node, then we can dequeue the old head.
            if (next) |new_head| {
                self.head = new_head;
                return head;
            }

            // Theres no node next after the head meaning the queue might be in an inconsistent state.
            const tail = @atomicLoad(*Task, &self.queue.tail, .Acquire);
            if (head != tail) {
                return null;
            }

            // The queue is not in an inconsistent state and our head node is still valid
            // In order to dequeue it, we must push back the stub node so that there will always be a tail if we do.
            self.queue.push(self.stub);

            // Try and dequeue the head node as mentioned above.
            next = @atomicLoad(?*Task, &head.next, .Acquire);
            if (next) |new_head| {
                self.head = new_head;
                return head;
            }

            return null;
        }
    };
};

/// A bounded, Single-Producer-Multi-Consumer (SPMC) queue of tasks which supports batch push/pop operations.
const BoundedQueue = extern struct {
    head: usize = 0,
    tail: usize = 0,
    buffer: [capacity]*Task = undefined,

    const capacity = 256;

    /// Tries to enqueue a Batch entity to this BoundedQueue, returning a batch of tasks that overflowed in the process (amortized).
    fn push(self: *BoundedQueue, entity: anytype) ?Batch {
        var batch = Batch.from(entity);
        var tail = self.tail;
        var head = @atomicLoad(usize, &self.head, .Monotonic);

        while (true) {
            if (batch.isEmpty()) {
                return null;
            }

            var remaining = capacity - (tail -% head);
            if (remaining > 0) {
                // Unordered store to buffer to avoid UB as stealer threads could be racy-reading in parallel
                while (remainig > 0) : (remaining -= 1) {
                    const task = batch.pop() orelse break;
                    @atomicStore(*Task, &self.buffer[tail % capacity], task, .Unordered);
                    tail +%= 1;
                }

                // Release barrier to ensure stealer threads see valid task writes when loading from the tail w/ Acquire.
                @atomicStore(usize, &self.tail, tail, .Release);

                // Retry to push tasks as theres a possibility stealer threads could have dequeued & made more room in the buffer.
                spinLoopHint();
                head = @atomicLoad(usize, &self.head, .Monotonic);
                continue;
            }

            // The buffer is full, try to move half of the tasks out to allow the fast-path pushing above next times.
            // Acquire barrier on success to ensure that the writes we do to the migrated tasks don't get reordered before we commit the migrate.
            const new_head = head +% (capacity / 2);
            if (@cmpxchgWeak(
                usize,
                &self.head,
                head,
                new_head,
                .Acquire,
                .Monotonic,
            )) |updated| {
                head = updated;
                continue;
            }

            // Create a batch of the tasks we migrated ...
            var overflowed = Batch{};
            while (head != new_head) : (head +% 1) {
                const task = self.buffer[head % capacity];
                overflowed.push(task);
            }
            
            // ... and move them all to the front of the batch, returning everything remaining as overflowed.
            overflowed.pushBack(batch);
            return overflowed;
        }
    }

    /// Tries to dequeue a single task from the BoundedQueue, competing with other stealer threads.
    fn pop(self: *BoundedQueue) ?*Task {
        var tail = self.tail;
        var head = @atomicLoad(usize, &self.head, .Monotonic);

        while (true) {
            if (tail == head) {
                return null;
            }

            // Acquire barrier on successful pop to prevent any writes we do to the stolen tasks from being reordered before the pop.
            head = @cmpxchgWeak(
                usize,
                &self.head,
                head,
                head +% 1,
                .Acquire,
                .Monotonic,
            ) orelse return self.buffer[head % capacity];
        }
    }

    /// Dequeues a batch of tasks from the target BoundedQueue into our BoundedQueue (work-stealing).
    fn popAndStealBounded(self: *BoundedQueue, target: *BoundedQueue) ?*Task {
        // Stealing from ourselves just checks our own buffer
        if (target == self) {
            return self.pop();
        }
        
        // If our own queue isn't empty, we shouldn't be stealing from others
        const tail = self.tail;
        const head = @atomicLoad(usize, &self.head, .Monotonic);
        if (tail != head) {
            return self.pop();
        }

        // Acquire barrier on the target.tail load to observe Released writes it's target.buffer tasks.
        var target_head = @atomicLoad(usize, &target.head, .Monotonic);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.tail, .Acquire);
            const target_size = target_tail -% target_head;

            // Try to steal half of the target's buffer tasks to amortize the cost of stealing
            var steal = target_size - (target_size / 2);
            if (steal == 0) {
                return null;
            }

            // Reload the head & tail if they become un-sync'd as they're observed separetely 
            if (steal > capacity / 2) {
                spinLoopHint();
                target_head = @atomicLoad(usize, &target.head, .Monotonic);
                continue;
            }

            // We will be returning the first stolen task (hence "popAndSteal")
            const first_task = @atomicLoad(*Task, &target.buffer[target_head % capacity], .Unordered);
            var new_target_head = target_head +% 1;
            var new_tail = tail;
            steal -= 1;

            // Racy-copy the targets tasks from their buffer into ours.
            // Unordered load on targets buffer to avoid UB as it could be writing to it in push().
            // Unordered store on our buffer to avoid UB as other threads could be racy-reading from ours as above.
            while (steal > 0) : (steal -= 1) {
                const task = @atomicLoad(*Task, &target.buffer[new_target_head % capacity], .Unordered);
                new_target_head +%= 1;
                @atomicStore(*Task, &self.buffer[new_tail % capacity], task, .Unordered);
                new_tail +%= 1;
            }

            // Try to mark the tasks we racy-copied into our buffer from the target's as "stolen".
            // Release on success to ensure that the copies above don't get reordering after the commit of the steal.
            if (@cmpxchgWeak(
                usize,
                &target.head,
                target_head,
                new_target_head,
                .Release,
                .Monotonic,
            )) |updated| {
                target_head = updated;
                continue;
            }

            // If we added any tasks to our local buffer, update our tail to mark then as push()'d.
            // Release barrier to ensure stealer threads see valid task writes when loading from the tail w/ Acquire (above)
            if (new_tail != tail) {
                @atomicStore(usize, &self.tail, new_tail, .Release);
            }

            return first_task;
        }
    }

    /// Dequeues a batch of tasks from the target UnboundedQueue into our BoundedQueue.
    fn popAndStealUnbounded(self: *BoundedQueue, target: *UnboundedQueue) ?*Task {
        // Try to acquire ownership of the consuming side of the UnboundedQueue in order to pop tasks from it
        var consumer = target.tryAcquireConsumer() orelse return null;
        defer consumer.release();

        // Will be returning the first task (hence "popAndSteal")
        const first_task = consumer.pop();
        
        // Return whatever was popped if our local buffer is full
        const tail = self.tail;
        const head = @atomicLoad(usize, &self.head, .Monotonic);
        if (tail == head) {
            return first_task;
        }

        // Try to push tasks into our local buffer using the consumer side of the UnboundedQueue.
        // Unordered stores on our buffer to avoid UB as other threads could be racy-reading from it (see "popAndStealBounded").
        var new_tail = tail;
        var remaining = capacity - (tail -% head); 
        while (remaining > 0) : (remaining -= 1) {
            const task = consumer.pop() orelse break;
            @atomicStore(*Task, &self.buffer[new_tail % capacity], task, .Unordered);
            new_tail +%= 1;
        }

        // If we added any tasks to our local buffer, update our tail to mark then as push()'d.
        // Release barrier to ensure stealer threads see valid task writes when loading from the tail w/ Acquire (above)
        if (new_tail != tail) {
            @atomicStore(usize, &self.tail, new_tail, .Release);
        }

        return first_task;
    }
};

const ActiveQueue = struct {
    head: ?*Node = null,

    const Node = struct {
        next: ?*Node = null,
    };

    const Iter = struct {
        node: ?*Node,

        fn next(self: *Iter) ?*Node {
            const node = self.node;
            self.node = node.next;
            return node;
        }
    };

    fn push(self: *ActiveQueue, node: *Node) void {
        var head = @atomicLoad(?*Node, &self.head, .Monotonic);

        while (true) {
            node.next = head;
            head = @cmpxchgWeak(
                ?*Node,
                &self.head,
                head,
                node,
                .Release,
                .Monotonic,
            ) orelse break;
        }
    }

    fn iter(self: *ActiveQueue) Iter {
        const node = @atomicLoad(?*Node, &self.head, .Acquire);
        return Iter{ .node = node };
    }
};

const IdleQueue = struct {
    state: usize = EMPTY,

    const EMPTY: usize = 0;
    const NOTIFIED: usize = 1;
    const SHUTDOWN: usize = 2;
    const WAITING: usize = ~(EMPTY | NOTIFIED | SHUTDOWN);

    const Node = struct {
        next: ?*Node align(~WAITING + 1) = null,
    };

    const Wait = union(enum) {
        suspended: *Node,
        notified: void,
        shutdown: void,
    };

    fn wait(self: *IdleQueue, node: *Node) Wait {
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            if (state == SHUTDOWN) {
                return .shutdown;
            }

            if (state == NOTIFIED) {
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    EMPTY,
                    .Monotonic,
                    .Monotonic,
                ) orelse return .notified;
                continue;
            }

            node.next = blk: {
                @setRuntimeSafety(false);
                break :blk @intToPtr(?*Node, state & WAITING);
            };

            state = @cmpxchgWeak(
                usize
                &self.state,
                state,
                @ptrToInt(node),
                .Release,
                .Monotonic,
            ) orelse return .{ .waiting = node };
        }
    }

    const Notify = union(enum) {
        resumed: *Node,
        notified: void,
        shutdown: void,
    };

    fn notify(self: *IdleQueue) Notify {
        var state = @atomicLoad(usize, &self.state, .Acquire);

        while (true) {
            if (state == SHUTDOWN) {
                return .shutdown;
            }

            if (state == EMPTY) {
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    NOTIFIED,
                    .Acquire,
                    .Acquire,
                ) orelse return .notified;
                continue;
            }

            const node = blk: {
                @setRuntimeSafety(false);
                break :blk @intToPtr(?*Node, state & WAITING);
            };

            state = @cmpxchgWeak(
                usize
                &self.state,
                state,
                @ptrToInt(node.next),
                .Acquire,
                .Acquire,
            ) orelse return .{ .resumed = node };
        }
    }

    const Iter = struct {
        node: ?*Node,

        fn next(self: *Iter) ?*Node {
            const node = self.node;
            self.node = node.next;
            return node;
        }
    };

    fn shutdown(self: *IdleQueue) Iter {
        const state = @atomicRmw(usize, &self.state, .Xchg, SHUTDOWN, .Acquire);

        const node = switch (state) {
            NOTIFIED => null,
            SHUTDOWN => std.debug.panic("IdleQueue shutdown multiple times", .{}),
            else => blk: {
                @setRuntimeSafety(false);
                break :blk @intToPtr(?*Node, state & WAITING);
            },
        };

        return Iter{ .node = node };
    }
};

///////////////////////////////////////////////////////////////////////
// Platform Runtime API
///////////////////////////////////////////////////////////////////////

fn spinLoopHint() void {
    std.SpinLock.loopHint();
}

const OsFutex = struct {
    event: std.ResetEvent,

    fn init(self: *OsFutex) void {
        self.event = std.ResetEvent.init();
    }

    fn deinit(self: *OsFutex) void {
        self.event.deinit();
    }

    fn wait(self: *OsFutex, condition: anytype) void {
        self.event.reset();

        if (condition.poll()) {
            return;
        }

        self.event.wait();
    }

    fn wake(self: *OsFutex) void {
        self.event.set();
    }
};

const OsThread = struct {
    inner: std.Thread,

    threadlocal var tls_spawned: ?*OsThread = null;

    fn getSpawned() ?*OsThread {
        return tls_spawned;
    }

    const Affinity = struct {
        from_cpu: u16,
        to_cpu: u16,
    };

    const SpawnHints = struct {
        stack_size: ?usize = null,
        affinity: ?Affinity = null,
    };

    fn spawn(hints: SpawnHints, comptime entryFn: anytype, args: anytype) !*OsThread {
        const Args = @TypeOf(args);
        const Spawner = struct {
            fn_args: Args,
            inner: *std.Thread = undefined,
            inner_event: std.AutoResetEvent = std.AutoResetEvent{},
            spawn_event: std.AutoResetEvent = std.AutoResetEvent{},

            fn run(self: *Spawner) ReturnTypeOf(entryFn) {
                self.inner_event.wait();
                const fn_args = self.fn_args;
                const inner = self.inner;
                self.spawn_event.set();

                tls_spawned = @fieldParentPtr(OsThread, "inner", inner);
                return @call(.{}, entryFn, fn_args);
            }
        };

        var spawner = Spawner{ .fn_args = args };
        spawner.inner = try std.Thread.spawn(&spawner, Spawner.run);
        spawner.inner_event.set();
        spawner.spawn_event.wait();
        return @fieldParentPtr(OsThread, "inner", spawner.inner);
    }

    fn join(self: *OsThread) void {
        self.inner.wait();
    }
};