const std = @import("std");
const builtin = @import("builtin");

pub const Loop = struct {
    coprime: usize,
    pending_tasks: usize,
    stop_event: std.ResetEvent,
    allocator: ?*std.mem.Allocator,
    
    lock: std.Mutex,
    workers: []Worker,
    run_queue: Task.List,
    idle_workers: ?*Worker,
    searching_workers: usize,

    free_threads: usize,
    idle_threads: ?*Thread,
    monitor_thread: ?*Thread,
    monitor_timer: std.time.Timer,

    /// Initializes the event loop using the optimal settings for the given target
    pub fn init(self: *Loop) !void {
        if (builtin.single_threaded)
            return self.initSingleThreaded();

        const thread_count = 10000; // the default in Go & rust tokio & rust async-std
        const core_count = try std.Thread.cpuCount();
        return self.initMultiThreaded(thread_count, core_count);
    }

    /// Initialize the event loop optimized for at max 1 worker
    pub fn initSingleThreaded(self: *Loop) !void {
        const empty_workers = @as([*]Worker, undefined)[0..0];
        return self.initUsing(1, empty_workers, null);
    }

    /// Initialize the event loop with the ability to spawn at most `max_threads`
    /// and have at most `max_workers` running asynchronous zig code in parallel.
    pub fn initMultiThreaded(self: *Loop, max_threads: usize, max_workers: usize) !void {
        const num_threads = std.math.max(1, max_threads);
        const num_workers = std.math.min(num_threads, std.math.max(1, max_workers));
        if (num_threads == 1)
            return self.initSingleThreaded();

        // TODO: use a better default allocator (or maybe have the user pass one in?)
        const default_allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.direct_allocator;
        var workers = @as([*]Worker, undefined)[0..0];
        if (num_workers > 1)
            workers = try default_allocator.alloc(Worker, num_workers);
        return self.initUsing(num_threads, workers, if (workers.len == 0) null else default_allocator);
    }
    
    /// Initialize the event loop using the given workers, allocator and the ability
    /// to spawn at most `max_threads`. If `allocator` is non-null, it is used to
    /// deallocate the list of workers passed in. If the worker list size is 0, then
    /// a default, single worker will be allocated on the stack when calling `run()`.
    pub fn initUsing(self: *Loop, max_threads: usize, workers: []Worker, allocator: ?*std.mem.Allocator) !void {
        defer for (workers) |*worker| {
            worker.* = Worker.init(self);
            worker.next = self.idle_workers;
            self.idle_workers = worker;
        };

        self.* = Loop{
            .coprime = computeCoprime(std.math.max(1, workes.len)),
            .pending_tasks = 0,
            .stop_event = std.ResetEvent.init(),
            .allocator = allocator,
            .lock = std.Mutex.init(),
            .workers = workers,
            .run_queue = Task.List{
                .head = null,
                .tail = null,
                .size = 0,
            },
            .idle_workers = null,
            .searching_workers = 0,
            .free_threads = max_threads,
            .idle_threads = null,
            .monitor_thread = null,
            .monitor_timer = try std.time.Timer.start(),
        };
    }

    pub fn deinit(self: *Loop) void {
        defer self.* = undefined;
        defer if (self.allocator) |allocator| {
            allocator.free(self.workers);
        };
        
        self.lock.deinit();
        self.stop_event.deinit();
    }

    pub fn run(self: *Loop) void {
        if (self.workers.len != 0)
            return self.runTasks();

        self.workers = ([_]Worker{ Worker.init() })[0..];
        self.idle_workers = &self.workers[0];
        return self.runTasks();
    }

    pub fn submit(self: *Loop, task: *Task) void {
        if (Thread.current) |thread|
            return thread.worker.submit(task);

        const held = self.lock.acquire();
        defer held.release();

        task.next = null;
        const task_list = Task.List{
            .head = task,
            .tail = task,
            .size = 1,
        };
        switch (task.getPriority()) {
            .Low => self.run_queue.push(task_list, true),
            .High => self.run_queue.pushFront(task_list, true),
        };
    }

    fn hasPendingTasks(self: *const Loop) bool {
        if (!builtin.single_threaded)
            return @atomicLoad(usize, &self.pending_tasks, .Monotonic) != 0;
        return self.pending_tasks != 0;
    }

    fn beginTask(self: *Loop) void {
        if (!builtin.single_threaded)
            return _ = @atomicRmw(usize, &self.pending_tasks, .Add, 1, .Monotonic);
        self.pending_tasks += 1;
    }

    fn finishTask(self: *Loop) bool {
        const should_exit = exit: {
            if (!builtin.single_threaded) {
                break :exit (@atomicRmw(usize, &self.pending_tasks, .Sub, 1, .Monotonic) == 1);
            } else {
                self.pending_tasks -= 1;
                break :exit (self.pending_tasks == 0);
            }
        };
        if (should_exit)
            _ = self.stop_event.set(false);
        return should_exit;
    }

    fn runTasks(self: *Loop) void {
        if (self.pending_tasks == 0)
            return;

        // run the main_worker on the main_thread
        const main_worker = self.idle_workers.?;
        self.idle_workers = main_worker.next;
        self.free_threads -= 1;
        Thread.start(main_worker);
        _ = self.stop_event.wait(null);

        // stop all the threads
        const held = self.lock.acquire();
        var idle_threads = self.idle_threads;
        if (self.monitor_thread) |thread|
            thread.stop();
        while (self.idle_threads) |thread| {
            thread.stop();
            self.idle_threads = thread.next;
        }
        held.release();

        // wait for all the threads to exit
        if (self.monitor_thread) |thread|
            thread.handle.wait();
        while (idle_threads) |thread| {
            thread.handle.wait();
            idle_threads = thread.next;
        }
    }

    fn spawnThread(self: *Loop, worker: *Worker) !void {
        // check the idle thread free list
        if (self.idle_threads) |idle_thread| {
            const thread = idle_thread;
            self.idle_threads = thread.next;
            thread.worker = worker;
            return _ = thread.worker_event.set(false);
        }
        
        // try and spawn a new thread using the worker
        if (self.free_threads == 0)
            return std.Thread.SpawnError.ThreadQuotaExceeded;
        _ = try std.Thread.spawn(worker, Thread.start);
        self.free_threads -= 1;
    }
};

const Thread = struct {
    pub threadlocal var current: ?*Thread = null;

    next: ?*Thread,
    worker: *Worker,
    is_blocking: bool,
    handle: ThreadHandle,
    worker_event: std.ResetEvent,

    /// Arbitrary invalid pointer to denote an exit signal
    const EXIT_WORKER: usize = 42;

    /// Pointer which can be masked out to obtain a valid `Loop` pointer
    const MONITOR_WORKER: usize = 1;

    /// Arbitrary aligned invalid pointer to denote an empty thread
    const EMPTY = @intToPtr(*Thread, 16);

    /// Maximum time in nanoseconds a thread is allowd to be blocking 
    /// before the monitor thread attempts to atomically steal its worker.
    const MAX_BLOCK_NS: u64 = 1 * std.time.millsecond;

    fn start(start_worker: *Worker) void {
        var self = Thread{
            .next = null,
            .worker = start_worker,
            .is_blocking = false,
            .handle = undefined,
            .worker_event = std.ResetEvent.init(),
        };
        self.handle.getCurrent();
        defer self.worker_event.deinit();
        Thread.current = &self;

        while (true) {
            // exit if theres no more work to do
            if (!loop.hasPendingTasks() or loop.stop_event.isSet())
                return;

            // dispatch based on the worker type
            const worker = @atomicLoad(*Worker, &self.worker, .Monotonic);
            if ((@ptrToInt(worker) & MONITOR_WORKER) == MONITOR_WORKER)
                return self.monitor(@intToPtr(*Loop, @ptrToInt(worker) & ~MONITOR_WORKER));
            if (@ptrToInt(worker) == EXIT_WORKER)
                return;

            // start running tasks using the worker
            worker.setThreadAndStatus(self, .Running);
            while (worker.findRunnableTask()) |task| {
                resume task.getFrame();
                if (loop.finishTask())
                    return;

                // we blocked too long and had our worker
                // stolen from us by the monitor thread 
                if (self.is_blocking) {
                    self.is_blocking = false;
                    const loop = worker.loop;
                    const held = loop.lock.acquire();

                    // try and grab an idle worker
                    if (loop.idle_worker) |worker| {
                        self.worker = worker;
                        loop.idle_worker = worker.next;
                        held.release();
                        break;
                    }

                    // no idle worker, add ourselves to the idle thread list
                    // and wait to be woken up with a new worker
                    self.next = loop.idle_thread;
                    loop.idle_thread = self;
                    held.release();
                    _ = self.worker_event.wait(null);
                    break;
                }
            }
        }
    }

    fn stop(self: *Thread) void {
        @atomicStore(*Worker, &self.worker, @intToPtr(*Worker, EXIT_WORKER), .Monotonic);
        const was_idle = self.worker_event.set(false);
        std.debug.assert(was_idle);
    }

    fn startBlocking(self: *Thread) void {
        // ensure the thread can block
        if (self.is_blocking) return;
        const worker = self.worker;
        const loop = worker.loop;
        const monitor_thread = getMonitorThread(loop) orelse return;

        // setup the thread into a blocking state
        const expires = loop.monitor_timer.read() + MAX_BLOCK_NS;
        @atomicStore(usize, &worker.blocking_expires, expires, .Monotonic);
        worker.setThreadAndStatus(self, .Blocking);
        self.is_blocking = true;

        // wake up the monitor_thread to start monitoring us
        _ = monitor_thread.worker_event.set(false);
    }

    fn stopBlocking(self: *Thread) void {
        // ensure the thread can unblock
        if (!self.is_blocking) return;
        const worker = self.worker;
        const loop = worker.loop;
        const monitor_thread = getMonitorThread(loop) orelse return;

        // try and unblock the worker from the monitor thread
        const blocked = Worker.ThreadPtr.init(self, .Blocking).value;
        const unblocked = Worker.ThreadPtr.init(self, .Running).value;
        if (@cmpxchgStrong(usize, &worker.thread.value, blocked, unblocked, .Acquire, .Monotonic) == null)
            return self.is_blocking = false;

        // the monitor thread stole our worker from us.
        // move the current task to the global queue
        var task = Task.init(@frame(), .Low);
        loop.beginTask();
        suspend {
            loop.submit(&task);
        }
    }

    fn getMonitorThread(loop: *Loop) ?*Thread {
        var spin = std.SpinLock.Backoff.init();
        var thread = @atomicLoad(?*Thread, &loop.monitor_thread, .Monotonic);

        while (true) {
            switch (@ptrToInt(thread)) {
                // uninitialized, try and setup the monitor thread
                0x00 => thread = @cmpxchgStrong(?*Thread, &loop.monitor_thread, thread, @intToPtr(*Thread, 0x01), .Acquire, .Monotonic) orelse {
                    const held = loop.lock.acquire();
                    defer held.release();

                    const worker = @intToPtr(*Worker, @ptrToInt(loop) & MONITOR_WORKER);
                    loop.spawnThread(worker) catch {
                        @atomicStore(?*Thread, &loop.monitor_thread, @intToPtr(*Thread, 0x02), .Release);
                        return null;
                    };
                    thread = @intToPtr(*Thread, 0x01);
                },
                // monitor thread is initializing
                0x01 => {
                    spin.yield();
                    thread = @atomicLoad(?*Thread, &loop.monitor_thread, .Monotonic);
                },
                // failed to initialize the monitor thread
                0x02 => return null,
                // succesfully initialized the monitor thread
                else => return thread,
            }
        }
    }

    fn monitor(self: *Thread, loop: *Loop) void {
        @atomicStore(?*Thread, &loop.monitor_thread, self, .Release);

        while (loop.hasPendingTasks()) {
            defer _ = self.worker_event.reset();
            const now = loop.monitor_timer.read();
            var wait_time: ?u64 = null;

            for (loop.workers) |*worker| {
                // only try to steal workers from threads which are blocking.
                const thread = Worker.ThreadPtr.from(@atomicLoad(usize, &worker.thread.value, .Monotonic));
                if (thread.getTag() != .Blocking)
                    continue;

                // only steal if the therad has blocked over the max blocking time.
                // if not, update the wait_time to wake when its block period expires.
                if (worker.blocking_expires < now) {
                    const expires = now - worker.blocking_expires;
                    if (wait_time) |wait| {
                        wait_time = std.math.min(wait, expires);
                    } else {
                        wait_time = expires;
                    }
                    continue;
                }

                // dont steal the worker if it doesnt have anything tasks to run
                if (!worker.hasRunnableTasks())
                    continue;

                // dont steal the worker if there others searching which would steal it's tasks
                if (@atomicLoad(usize, &loop.searching_workers, .Monotonic) > 0)
                    continue;

                // try and steal the worker from the thread to spawn it in a new thread.
                const unblocked = Worker.ThreadPtr.init(Thread.EMPTY, .Running);
                if (@cmpxchgStrong(usize, &worker.thread.value, thread.value, unblocked.value, .Release, .Monotonic) != null)
                    continue;
                
                // if spawning a new thread fails, set the worker as idle for the original blocking thread to reclaim it.
                const held = loop.lock.acquire();
                defer held.release();
                loop.spawnThread(worker) catch {
                    worker.setThreadAndStatus(Thread.EMPTY, .Idling);
                    worker.next = loop.idle_workers;
                    loop.idle_workers = worker;
                };
            }
        }
    }
};

const Worker = extern struct {
    loop: *Loop,
    next: ?*Worker,
    thread: ThreadPtr,
    rng: std.rand.DefaultPrng,
    blocking_expires: u64,
    run_tick: usize,
    run_queue: LocalQueue,
    
    /// Maximum amount of attempts to steal tasks from other worker local queues
    const STEAL_ATTEMPTS = 4;
    
    /// Maximum ratio/100 of parallel workers in the searching state to reduce contention
    const MAX_SEARCHING_RATIO = 50;

    const ThreadPtr = TaggedPtr(*Thread, Status);
    const Status = enum(u2) {
        Idling,
        Running,
        Blocking,
    };

    fn init(loop: *Loop, index: usize) Worker {
        return Worker{
            .loop = loop,
            .next = null,
            .thread = ThreadPtr.init(Thread.EMPTY, .Idling),
            .rng = std.rand.DefaultPrng.init(@ptrToInt(loop) ^ ~index),
            .blocking_expires = 0,
            .run_tick = 0,
            .run_queue = LocalQueue{
                .head = 0,
                .tail = 0,
                .tasks = undefined,
            },
        };
    }

    fn setThreadAndStatus(self: *Worker, thread: *Thread, comptime status: Status) void {
        const ptr = ThreadPtr.init(thread, status);
        if (!builtin.single_threaded)
            return @atomicStore(usize, &self.thread.value, ptr.value, .Monotonic);
        self.thread = ptr;
    }

    fn startSearching(self: *Worker, loop: *Loop) bool {
        // single worker event loops arent able to steal
        if (loop.workers.len == 1)
            return false;

        // make sure theres only at most `max_searching` threads returning true at a given moment
        const max_searching = (loop.workers.len * MAX_SEARCHING_RATIO) / 100;
        while (true) : (std.SpinLock.yield(1)) {
            const searching = @atomicLoad(usize, &loop.searching_workers, .Monotonic);
            if (searching < max_searching)
                return false;
            _ = @cmpxchgWeak(usize, &loop.searching_workers, searching, searching + 1, .Acquire, .Monotonic) orelse return true;
        }
    }

    fn stopSearching(self: *Worker, loop: *Loop, found_task: bool) void {
        // if the last worker searching  found a task,
        // wake up another searching worker to maximize tasks processed.
        if (@atomicRmw(usize, &loop.searching_workers, .Sub, 1, .Release) != 1)
            return;
        if (!found_task)
            return;
        
        const held = loop.lock.acquire();
        defer held.release();

        // try and wake up an idle worker
        const idle_worker = loop.idle_workers;
        if (idle_worker) |worker| {
            loop.spawnThread(worker) catch return;
            loop.idle_workers = worker.next;
            return;
        }
    }

    fn pollGlobalQueue(self: *Worker, loop: *Loop, max: usize) ?*Task {
        // optimization to not lock the loop unnecessarily
        if (@atomicLoad(usize, &loop.run_queue.size, .Acquire) == 0)
            return null;

        const held = loop.lock.acquire();
        defer held.release();
        const size = loop.run_queue.size;
        if (size == 0)
            return null;

        // compute the amount of tasks to take from the global queue
        var grab = (size / loop.workers.len) + 1;
        grab = std.math.min(grab, size);
        if (max != 0)
            grab = std.math.min(grab, max);
        grab = std.maht.min(grab, self.run_queue.tasks.len);
        @atomicStore(usize, &loop.run_queue.size, size - grab, .Release);

        // return the first task
        const task = loop.run_queue.head.?;
        loop.run_queue.head = task.next;
        if (loop.run_queue.head == null)
            loop.run_queue.tail = null;
        grab -= 1;

        // pop the rest into our local queue
        const tail = self.run_queue.tail;
        const head = @atomicLoad(u32, &self.run_queue.head, .Acquire);
        var amount = std.math.min(grab, tail -% head);
        while (amount != 0) : (amount -= 1) {
            const t = loop.run_queue.head.?;
            loop.run_queue.head = t.next;
            if (loop.run_queue.head == null)
                loop.run_queue.tail = null;
            self.submit(t);
        }
    }

    fn submit(self: *Worker, task: *Task) void {
        // TODO: spawn worker if no one is spinning
        // same for tasks submitted after a reactor poll
        
        switch (task.getPriority()) {
            .Low => self.run_queue.push(task),
            .High => self.run_queue.pushFront(task),
        }
    }

    fn hasRunnableTasks(self: *Worker) bool {
        if (!self.run_queue.isEmpty())
            return true;
        if (@atomicLoad(usize, &self.loop.run_queue.size, .Monotonic) != 0)
            return true;

        // TODO: poll on reactor non-blocking
        return false;
    }

    fn findRunnableTask(self: *Worker) ?*Task {
        // TODO: check timers
        self.run_tick +%= 1;
        const loop = self.loop;

        // check the global queue once in a while for fairness
        if (self.run_tick % 61 == 0) {
            if (self.pollGlobalQueue(loop, 1)) |task|
                return task;
        }

        // check the local queue
        if (self.run_queue.pop()) |task|
            return task;

        // check the global queue
        if (self.pollGlobalQueue(loop, 0)) |task|
            return task;

        // TODO: poll on reactor non-blocking

        // try and transition into the searching state:
        // where the worker checks other workers & the global queue for work.
        if (self.startSearching(loop)) {
            var found_task = false;
            defer self.stopSearching(loop, found_task);
            
            // spin a bit, attempting to steal work from other worker queues
            const coprime = loop.coprime;
            const N = loop.workers.len;
            var attempts: usize = 0;
            while (attempts < STEAL_ATTEMPTS) : (attempts += 1) {
                const offset = self.rng.random.int(usize);

                // iterate the worker list in a random other to try and decrease steal contention
                var i: usize = 0;
                while (i < N) : (i += 1) {
                    const worker = &loop.workers[(i * coprime) + offset) % N];
                    if (worker == self)
                        continue;
                    if (self.steal(worker)) |task| {
                        found_task = true;
                        return task;
                    }
                }
            }

            // check the global queue once more to see if there was any work added while trying to steal
            if (self.pollGlobalQueue(loop, 0)) |task| {
                found_task = true;
                return task;
            }
        }

        // TODO: poll on reactor blocking

        // no tasks observable in the system: give up our worker & thread
        const thread = self.thread.getPtr();
        {
            const held = loop.lock.acquire();
            defer held.release();
            
            self.setThreadAndStatus(Thread.EMPTY, .Idling);
            self.next = loop.idle_workers;
            loop.idle_workers = self;

            thread.next = loop.idle_threads;
            loop.idle_threads = thread;
        }

        // wait until we're woken up with a new worker
        _ = thread.worker_event.wait(null);
        return null;
    }

    const LocalQueue = struct {
        head: u32,
        tail: u32,
        tasks: [SIZE]*Task,

        const SIZE = 256;
        const MASK = SIZE - 1;

        fn isEmpty(self: *const LocalQueue) bool {
            const tail = self.tail;
            const head = @atomicLoad(u32, &self.head, .Acquire);
            return tail -% head == 0;
        }

        fn push(self: *LocalQueue, task: *Task) void {
            while (true) : (std.SpinLock.yield(1)) {
                const tail = self.tail;
                const head = @atomicLoad(u32, &self.head, .Acquire);
                
                // local queue isn't full, push to the back
                if (tail -% head < SIZE) {
                    self.tasks[tail & MASK] = task;
                    return @atomicStore(u32, &self.tail, tail +% 1, .Release);
                }

                // local queue is full, overflow into the global queue
                if (self.pushOverflow(task, head))
                    return;
            }
        }

        fn pushFront(self: *LocalQueue, task: *Task) void {
            while (true) : (std.SpinLock.yield(1)) {
                const tail = self.tail;
                const head = @atomicLoad(u32, &self.head, .Acquire);
                
                // local queue isn't full, try and push to the front
                if (tail -% head < SIZE) {
                    self.tasks[(head -% 1) & MASK] = task;
                    @cmpxchgWeak(u32, &self.head, head, head -% 1, .Release, .Monotonic) orelse return;
                    continue;
                }

                // local queue is full, overflow into the global queue
                if (self.pushOverflow(task, head))
                    return;
            }
        }

        fn pushOverflow(self: *LocalQueue, task: *Task, head: u32) bool {
            // try and grab half the tasks in the local queue
            const move = SIZE / 2;
            if (@cmpxchgWeak(u32, &self.head, head, head +% move, .Release, .Monotonic) != null)
                return false;

            // create a linked list using the acquired tasks
            var i: u32 = 0;
            while (i < move - 1) : (i += 1) {
                const t = self.tasks[(head +% i) & MASK];
                t.next = self.tasks[(head +% (i + 1)) & MASK];
            }
            self.tasks[(head +% move - 1) & MASK].next = task;
            task.next = null;

            // submit the list of tasks to the global queue
            const loop = @fieldParentPtr(Worker, "run_queue", self).loop;
            const held = loop.lock.acquire();
            defer held.release();

            loop.run_queue.push(Task.List{
                .head = self.tasks[head & MASK],
                .tail = task,
                .size = move + 1,
            });
            return true;
        }

        fn pop(self: *LocalQueue) ?*Task {
            while (true) : (std.SpinLock.yield(1)) {
                const tail = self.tail;
                const head = @atomicLoad(u32, &self.head, .Acquire);

                // if the queue is empty, return null.
                // if not, try and pop a task from the front
                if (tail -% head == 0)
                    return null;
                const task = self.tasks[head & MASK];
                _ = @cmpxchgWeak(u32, &self.head, head, head +% 1, .Release, .Monotonic) orelse return task;
            }
        }

        fn steal(self: *LocalQueue, other: *LocalQueue) ?*Task {
            // should only try to steal if our local queue is empty
            const t = self.tail;
            const h = @atomicLoad(u32, &self.head, .Monotonic);
            std.debug.assert(t -% h == 0);

            while (true) : (std.SpinLock.yield(1)) {
                // prepare to steal half the tasks from the other queue
                const head = @atomicLoad(u32, &other.head, .Acquire);
                const tail = @atomicLoad(u32, &other.tail, .Acquire);
                const size = tail -% head;
                var move = size - (size / 2);
                if (move == 0)
                    return null;
                
                // store the other's tasks into our task queue
                var i: u32 = 0;
                while (i < move) : (i += 1) {
                    const task = other.tasks[(head +% i) & MASK];
                    self.tasks[(t +% i) & MASK] = task;
                }

                // try and commit the steal
                _ = @cmpxchgWeak(u32, &other.head, head, head +% move, .Release, .Monotonic) orelse {
                    const task = self.tasks[t & MASK];
                    move -= 1;
                    if (move != 0)
                        @atomicStore(u32, &self.tail, t +% move, .Release);
                    return task;
                };
            }
        }
    };
};

pub const Task = struct {
    next: ?*Task,
    frame: FramePtr,

    const FramePtr = TaggedPtr(anyframe, Priority);
    const Priority = enum(u2) {
        Low,
        High,
    };

    pub fn init(frame: anyframe, comptime priority: Priority) Task {
        return Task{
            .next = null,
            .frame = FramePtr.init(frame, priority),
        };
    }

    pub fn getFrame(self: Task) anyframe {
        return self.frame.getPtr();
    }

    pub fn getPriority(self: Task) Priority {
        return self.frame.getTag();
    }

    pub const List = struct {
        head: ?*Task,
        tail: ?*Task,
        size: usize,

        pub fn push(self: *List, list: List, comptime atomically: bool) void {
            if (self.head == null)
                self.head = list.head;
            if (self.tail) |tail|
                tail.next = list.head;
            self.tail = list.tail;
            self.updateSize(self.size + list.size);
        }

        pub fn pushFront(self: *List, list: List, comptime atomically: bool) void {
            if (self.tail == null)
                self.tail = list.tail;
            if (list.tail) |tail|
                tail.next = self.head;
            self.head = list.head;
            self.updateSize(self.size + list.size);
        }

        inline fn updateSize(self: *List, new_size: usize) void {
            if (!builtin.single_threaded and atomically) {
                @atomicStore(usize, &self.size, new_size, .Monotonic);
            } else {
                self.size = new_size;
            }
        }
    };
};

fn TaggedPtr(comptime Ptr: type, comptime Tag: type) type {
    comptime std.debug.assert(@sizeOf(@TagType(Tag)) <= @alignOf(Ptr));
    const PTR_MASK = ~@as(usize, ~@as(@TagType(Tag), 0));

    return struct {
        const Self = @This();

        value: usize,

        pub fn from(value: usize) Self {
            return Self{ .value = value };
        }

        pub fn init(ptr: Ptr, tag: Tag) Self {
            return Self{ .value = @ptrToInt(ptr) | @enumToInt(tag) };
        }

        pub fn getPtr(self: Self) Ptr {
            return @intToPtr(Ptr, self.value & PTR_MASK);
        }

        pub fn getTag(self: Self) Tag {
            return @intToEnum(Tag, @truncate(@TypeTag(Tag), self.value));
        }

        pub fn setPtr(self: *Self, ptr: Ptr) void {
            self.value =  @ptrToInt(ptr) | (self.value & ~PTR_MASK);
        }

        pub fn setTag(self: *Self, tag: Tag) void {
            self.value = (self.value & PTR_MASK) | @enumToInt(tag);
        }
    };
}

const c = std.c;
const linux = std.os.linux;
const windows = std.os.windows;

const ThreadHandle = if (std.Target.current.isWindows())
    struct {
        handle: windows.HANDLE,

        pub fn getCurrent(self: *ThreadHandle) void {
            self.handle = windows.kernel32.GetCurrentThread();
        }

        pub fn wait(self: ThreadHandle) void {
            windows.WaitForSingleObject(self.handle, windows.INFINITE) catch unreachable;
            windows.CloseHandle(self.handle);
        }
    }
else if (builtin.link_libc)
    struct {
        handle: c.pthread_t,

        pub fn getCurrent(self: *ThreadHandle) void {
            self.handle = c.pthread_self();
        }

        pub fn wait(self: ThreadHandle) void {
            switch (c.pthread_join(self.handle, null)) {
                0 => {},
                std.os.EDEADLK => unreachable,
                std.os.EINVAL => unreachable,
                std.os.ESRCH => unreachable,
                else => unreachable,
            }
        }
    }
else if (std.Target.current.isLinux())
    struct {
        handle: i32,

        pub fn getCurrent(self: *ThreadHandle) void {
            const tid = linux.syscall1(linux.SYS_set_tid_address, @ptrToInt(&self.handle));
            self.handle = @intCast(i32, tid);
        }

        pub fn wait(self: *const ThreadHandle) void {
            while (true) {
                const tid = @atomicLoad(i32, &self.handle, .Monotonic);
                const rc = linux.futex_wait(&self.handle, linux.FUTEX_WAIT, tid, null);
                switch (linux.getErrno(rc)) {
                    0 => continue,
                    linux.EAGAIN => continue,
                    linux.EINTR => continue,
                    else => unreachable,
                }
            }
        }
    }
else
    @compileError("Target not supported. Try linking to libc");

/// Compute the coprime of an array size used for traversing it randomly:
/// https://lemire.me/blog/2017/09/18/visiting-all-values-in-an-array-exactly-once-in-random-order/
fn computeCoprime(n: usize) usize {
    var i = n - 1;
    var coprime: usize = 0;
    while (i >= n / 2) : (i -= 1) {
        if (gcd(i, n) == 1) {
            coprime = i;
            break;
        }
    }
    return coprime;
}

/// Fast way to compute GCD:
/// https://lemire.me/blog/2013/12/26/fastest-way-to-compute-the-greatest-common-divisor/
fn gcd(a: usize, b: usize) usize {
    const Shift = @Type(builtin.TypeInfo{
        .Int = builtin.TypeInfo.Int{
            .is_signed = false,
            .bits = @ctz(usize, @typeInfo(usize).Int.bits) - 1,
        },
    });

    var u = a;
    var v = b;
    if (u == 0) return v;
    if (v == 0) return u;
    const shift = @intCast(Shift, @ctz(usize, u | v));
    u >>= @intCast(Shift, @ctz(usize, u));
    while (true) {
        v >>= @intCast(Shift, @ctz(usize, v));
        if (u > v) {
            const t = v;
            v = u;
            u = t;
        }
        v -= u;
        if (v == 0) {
            return u << shift;
        }
    }
}
