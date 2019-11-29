const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

usingnamespace @import("reactor.zig");
usingnamespace switch (builtin.os) {
    .windows => @import("platform/windows.zig"),
    .linux => @import("platform/linux.zig"),
    else => @import("platform/unix.zig"),
};

pub const Executor = struct {
    const instance = std.event.Loop.instance orelse 
        @compileError("A valid executor is required");

    // general executor fields
    active_tasks: usize,
    stop_event: std.ResetEvent,
    reactor_lock: u32,
    reactor: Reactor,
    allocator: ?*std.mem.Allocator,
    

    // thread fields
    thread_lock: std.Mutex,
    idle_threads: ?*Thread,
    free_threads: usize,
    monitor_thread: ?*Thread,
    monitor_tick: u64,

    // worker fields
    runq_lock: std.Mutex,
    runq: Task.List,
    coprime: usize,
    workers: []Worker,
    searching_workers: usize,
    idle_workers: ?*Worker,
    idle_worker_lock: std.Mutex,    

    pub fn init(self: *Executor) !void {
        if (builtin.single_threaded)
            return self.initSingleThreaded();
        
        const max_threads = 1024;
        const max_workers = try std.Thread.cpuCount();
        return self.initMultiThreaded(max_workers, max_threads);
    }

    pub fn initSingleThreaded(self: *Executor) !void {
        return self.initUsing(@as([*]Worker, undefined)[0..0], 1, null);
    }

    pub fn initMultiThreaded(self: *Executor, max_workers: usize, max_threads: usize) !void {
        const num_threads = std.math.max(1, max_threads);
        const num_workers = std.math.min(num_threads, std.math.max(1, max_workers));
        if (num_threads == 1)
            return self.initSingleThreaded();

        // TODO: Use a better allocator
        const allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.direct_allocator;
        const workers = try allocator.alloc(Worker, num_workers);
        return self.initUsing(workers, num_threads, allocator);
    }

    pub fn initUsing(self: *Executor, workers: []Worker, max_threads: usize, allocator: ?*std.mem.Allocator) !void {
        self.* = Executor{
            .active_tasks = 0,
            .stop_event = std.ResetEvent.init(),
            .reactor = try Reactor.init(),
            .reactor_lock = 0,
            .allocator = allocator,
            .thread_lock = std.Mutex.init(),
            .idle_threads = null,
            .free_threads = max_threads,
            .monitor_thread = null,
            .monitor_tick = 0,
            .runq_lock = std.Mutex.init(),
            .runq = Task.List{
                .head = null,
                .tail = null,
                .size = 0,
            },
            .coprime = computeCoprime(workers.len),
            .workers = workers,
            .searching_workers = 0,
            .idle_workers = null,
            .idle_worker_lock = std.Mutex.init(),         
        };
        for (workers) |*worker| {
            worker.* = Worker.init();
            self.idle_workers = worker;
        }
    }

    pub fn deinit(self: *Executor) void {
        self.reactor.deinit();
        self.stop_event.deinit();
        self.runq_lock.deinit();
        self.thread_lock.deinit();
        self.idle_worker_lock.deinit();
        if (self.allocator) |allocator| {
            allocator.free(self.workers);
        }
    }

    // dummy functions to keep start.zig happy
    pub fn beginOneEvent(self: *Executor) void {}
    pub fn finishOneEvent(self: *Executor) void {}

    pub fn run(self: *Executor) void {
        // get an idle worker or use one from the stack in single threaded mode
        self.free_threads -= 1;
        const main_worker = self.idle_workers orelse {
            self.workers = ([_]Worker{ Worker.init() })[0..];
            return Thread.run(&self.workers[0]);
        };

        // run the main_worker and wait for the stop_event to be set
        self.idle_workers = main_worker.next;
        Thread.run(main_worker);
        _ = self.stop_event.wait(null);

        // wait for the monitor thread to exit if there is one
        if (self.monitor_thread) |monitor_thread| {
            _ = monitor_thread.worker_event.set(false);
            monitor_thread.handle.join();
        }

        // wait for all the idle threads to exit
        const held = self.thread_lock.acquire();
        defer held.release();
        var idle_threads = self.idle_threads;
        while (idle_threads) |thread| {
            thread.wakeWith(Thread.EXIT_WORKER);
            idle_threads = thread.next;
        }
        while (self.idle_threads) |thread| {
            thread.handle.join();
            self.idle_threads = thread.next;
        }
    }

    pub fn yield() void {
        const thread = Thread.current orelse return;
        return thread.worker.yield();
    }

    pub fn blocking(self: *Executor, comptime func: var, args: ...) @typeOf(func).ReturnType {
        const thread = Thread.current orelse return func(args);
        return thread.worker.blocking(func, args);
    }

    fn hasPendingTasks(self: *const Executor) bool {
        if (builtin.single_threaded)
            return self.active_tasks > 0;
        return @atomicLoad(usize, &self.active_tasks, .Acquire) > 0;
    }

    fn finishTask(self: *Executor) bool {
        if (!builtin.single_threaded)
            return @atomicRmw(usize, &self.active_tasks, .Sub, 1, .Release) == 1;
        const previous = self.active_tasks;
        self.active_tasks -= 1;
        return previous == 1;
    }

    /// Pushes tasks into the global queue and starts up idle worker threads to execute them.
    pub fn submitTasks(self: *Executor, list: Task.List) void {
        if (list.size == 0) return;
        self.pushTasks(list);

        const held = self.idle_worker_lock.acquire();
        defer held.release();

        var i = list.size;
        while (i != 0) : (i -= 1) {
            const worker = self.idle_workers orelse return;
            self.spawnThread(worker) catch return;
            self.idle_workers = worker.next;
        }
    }

    fn pollReactorTasks(self: *Executor, blocking: bool) ?*Task {
        if (@atomicRmw(u32, &self.reactor_lock, .Xchg, 1, .Acquire) != 0)
            return null;
        var tasks = self.reactor.poll(blocking);
        @atomicStore(u32, &self.reactor_lock, 0, .Release);

        const task = tasks.pop() orelse return null;
        tasks.size -= 1;
        self.submitTasks(tasks);
        return task;
    }

    fn pushTasks(self: *Executor, list: Task.List) void {
        const held = self.runq_lock.acquire();
        defer held.release();

        // use an atomic store for the optimization below
        defer self.runq.push(list);
        if (builtin.single_threaded) {
            self.runq.size += list.size;
        } else {
            @atomicStore(usize, &self.runq.size, self.runq.size + list.size, .Monotonic);
        }
    }

    fn popTasks(self: *Executor, worker: *Worker, max: ?usize) ?*Task {
        // single threaded simply pops from global queue until the worker queue is full
        if (builtin.single_threaded) {
            while (self.runq.head) |head| {
                if (worker.runq_tail -% worker.runq_head != worker.runq.len) {
                    break;
                } else {
                    worker.runq[worker.runq_tail % worker.runq.len] = head;
                    self.runq.head = head.next;
                    worker.runq_tail +%= 1;
                }
            }
        }

        // optimization to not acquire the mutex
        if (@atomicLoad(usize, &self.runq.size, .Monotonic) == 0)
            return null;

        // acquire the lock & try to pop some tasks
        const held = self.runq_lock.acquire();
        defer held.release();
        if (self.runq.size == 0)
            return null;

        
        // compute how many tasks to grab from the global run queue
        var size = (self.runq.size / self.workers.len) + 1;
        size = std.math.min(size, max orelse std.math.maxInt(usize));
        size = std.math.min(size, worker.runq.len);
        @atomicStore(usize, &self.runq.size, self.runq.size - size, .Monotonic);

        // pop one since will be returning it & push the rest to the worker's queue
        size -= 1;
        const task = self.runq.pop();
        while (size > 0) : (size -= 1) {
            worker.push(self.runq.pop().?);
        }
    }

    /// A thread is transitioning into the searching state after having not
    /// found any tasks in its local queue, the global queue and the reactor.
    /// Once in a searching state, the thread tries to steal work from other workers.
    /// Limit the amount of search threads to half the executors workers to decrease contention:
    /// https://tokio.rs/blog/2019-10-scheduler/#throttle-stealing
    fn startSearching(self: *Executor) bool {
        const searching = @atomicRmw(usize, &self.searching_workers, .Add, 1, .Monotonic);
        return searching <= self.workers.len;
    }

    fn stopSearching(self: *Executor, idle_worker: ?*Worker) void {
        const worker = idle_worker orelse {
            const 
        };
    }

    fn setIdleWorker(self: *Executor, worker: *Worker) void {
        const held = self.idle_worker_lock.acquire();
        defer held.release();

        worker.next = self.idle_workers;
        self.idle_workers = worker;
    }

    fn setIdleThread(self: *Executor, thread: *Thread) void {
        const held = self.thread_lock.acquire();
        defer held.release();

        thread.next = self.idle_threads;
        self.idle_threads = thread;
    }

    fn spawnThread(self: *Executor, worker: *Worker) std.Thread.SpawnError!void {
        const held = self.thread_lock.acquire();
        defer held.release();

        // try using a thread in the free list
        if (self.idle_threads) |idle_thread| {
            const thread = idle_thread;
            self.idle_threads = thread.next;
            thread.wakeWith(worker);
            return;
        }

        // free list is empty, try and spawn a new thread
        if (self.free_threads == 0)
            return std.Thread.SpawnError.ThreadQuotaExceeded;
        self.free_threads -= 1;
        platform.Thread.spawn(worker, Thread.run) catch |err| {
            self.free_threads = 0; // assume hit thread limit on error
            return err;
        };
    }

    fn monitor(self: *Executor, thread: *Thread) void {
        // TODO: monitor blocking threads
    }

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
};

const Thread = struct {
    threadlocal var current: ?*Thread = null;

    next: ?*Thread,
    worker: *Worker,
    handle: platform.Thread,
    worker_event: std.ResetEvent,

    const EXIT_WORKER = @intToPtr(*Worker, 0x1);
    const MONITOR_WORKER = @intToPtr(*Worker, 0x2);

    fn wakeWith(self: *Thread, worker: *Worker) void {
        self.worker = worker;
        _ = self.worker_event.set(false);
    }

    fn run(worker: *Worker) void {
        var self = Thread{
            .next = null,
            .worker = worker,
            .handle = undefined,
            .worker_event = std.ResetEvent.init(),
        };
        self.handle.getCurrent();
        defer self.worker_event.deinit();
        Thread.current = &self;
        const executor = Executor.instance;

        // the thread is a monitor thread
        if (self.worker == MONITOR_WORKER) {
            return executor.monitor(self);
        }

        // keep polling for work using the given worker
        while (true) {
            const worker = self.worker;
            const task = worker.findRunnableTask() orelse return;
            resume task.getFrame();

            if (executor.finishTask()) {
                _ = executor.stop_event.set(false);
                return;
            }

            // TODO: handle blocking tasks
        }
    }

    fn monitor(self: *Thread) void {
        // TODO
    }
};

const Worker = struct {
    const IndexShift = @typeInfo(Index).Int.bits;
    const Index = switch (@sizeOf(usize)) {
        @sizeOf(u64) => u32,
        @sizeOf(u32) => u16,
        else => @compileError("platform not supported"),
    };

    runq_head: Index,
    runq_tail: Index,
    runq: [256]*Task,
    runq_tick: usize,

    next: ?*Worker,
    thread: *Thread,
    monitor_tick: u64,
    rng: std.rand.DefaultPrng,

    fn init() Worker {
        const seed = @as(u64, @ptrToInt(Executor.instance)) ^ platform.nanotime();
        return Worker{
            .runq_head = 0,
            .runq_tail = 0,
            .runq = undefined,
            .runq_tick = 0,
            .next = null,
            .thread = undefined,
            .monitor_tick = 0,
            .rng = std.rand.DefaultPrng(seed),
        };
    }

    fn findRunnableTask(self: *Worker) ?*Task {
        self.runq_tick +%= 1;
        const executor = Executor.instance;
        const workers = &executor.workers;

        // check the global queue once in a while
        if (self.runq_tick % 61 == 0) {
            if (executor.popTasks(self, 1)) |task| {
                return task;
            }
        }

        // mostly pop from local queue LIFO (front) but do FIFO (back) occasionally for fairness
        if (switch (self.runq_tick % 31 == 0) {
            true => self.popBackTask(),
            else => self.popFrontTask(),
        }) |task| {
            return task;
        }

        // try and poll on the network (non-blocking)
        if (executor.pollReactorTasks(false)) |task| {
            return task;
        }

        // start spinning for new tasks
        while (true) {
            if (!executor.hasPendingTasks())
                return null;

            if (executor.startSearching()) {
                // try and steal work for other workers, iterating them in a random order
                var attempts: usize = 0;
                const coprime = executor.coprime;
                while (attempts < 4) : (attempts += 1) {
                    const offset = self.rng.random.int(usize);

                    var i: usize = 0;
                    while (i < workers.len) : (i += 1) {
                        const index = ((i * coprime) + offset) % workers.len;
                        if (self.steal(workers[index])) |task| {
                            executor.stopSearching(true);
                            return task;
                        }
                    }
                }

                // check the global queue once more in case anything was added while spinning
                if (Executor.instance.popTasks(self, 1)) |task| {
                    executor.stopSearching(true);
                    return task;
                }
            }

            // stop searching and try to poll the network indefinitely
            executor.stopSearching(false);
            if (executor.pollReactorTasks(true)) |task| {
                return task;
            }

            // someone else is polling the network.
            // set ourselves to idle, give up our thread and wait to be woken up.
            //  
        }
    }

    fn pushTask(self: *Worker, task: *Task) void {
        while (true) : (std.SpinLock.yield(1)) {
            const tail = self.runq_tail;
            const head = @atomicLoad(Index, &self.runq_head, .Acquire);
            const size = tail -% head;

            // if local queue isnt full, push to tail
            if (size < self.runq.len) {
                self.runq[tail % self.runq.len] = task;
                @atomicStore(Index, &self.runq_tail, tail +% 1, .Release);
                return;
            }
            
            // local queue is full, prepare to move half of it into global queue
            const migrate = size / 2;
            std.debug.assert(migrate == self.runq.len / 2);
            _ = @cmpxchgWeak(Index, &self.runq_head, head +% migrate, .Release, .Monotonic) orelse continue;

            // form a linked list of the tasks
            var i: Index = 0;
            task.next = null;
            self.runq[(head +% migrate - 1) % self.runq.len] = task;
            while (i < migrate) : (i += 1) {
                const t = self.runq[(head +% i) % self.runq.len];
                t.next = self.runq[(head +% (i + 1)) % self.runq.len];
            }

            // submit the linked list of the tasks to the global queue
            return Executor.instance.pushTasks(Task.List{
                .head = self.runq[head % self.runq.len],
                .tail = task,
                .size = migrate + 1
            });
        }
    }

    fn popBackTask(self: *LocalQueue) ?*Task {
        while (true) : (std.SpinLock.yield(1)) {
            const tail = self.runq_tail;
            const head = @atomicLoad(Index, &self.runq_head, .Acquire);
            if (tail -% head == 0) {
                return null;
            }

            const task = self.runq[head % self.runq.len];
            _ = @cmpxchgWeak(Index, &self.runq_head, head, head +% 1, .Release, .Monotonic) orelse return task;
        }
    }

    fn popFrontTask(self: *LocalQueue) ?*Task {
        while (true) : (std.SpinLock.yield(1)) {
            const tail = self.runq_tail;
            const head = @atomicLoad(Index, &self.runq_head, .Acquire);
            if (tail -% head == 0) {
                return null;
            }

            // manual double-sized cmpxchg which only updates
            // the tail if the head didnt change by a stealer.
            const task = self.runq[(tail -% 1) % self.runq.len];
            _ = @cmpxchgWeak(usize,
                @ptrCast(*usize, &self.runq_head),
                (@as(usize, head) << IndexShift) | @as(usize, tail),
                (@as(usize, head) << IndexShift) | @as(usize, tail -% 1),
                .Release,
                .Monotonic,
            ) orelse return task;
        }
    }

    fn steal(self: *LocalQueue, other: *LocalQueue) ?*Task {
        // only steal when self is empty
        const t = self.runq_tail;
        const h = @atomicLoad(Index, &self.runq_head, .Monotonic);
        std.debug.assert(t == h);

        while (true) : (std.SpinLock.yield(1)) {
            // acquire on both to synchronize with the producer & other stealers
            const head = @atomicLoad(Index, &other.runq_head, .Acquire);
            const tail = @atomicLoad(Index, &other.runq_tail, .Acquire);
            const size = tail -% head;
            if (size == 0) {
                return null;
            }

            // write the tasks locally
            var i: Index = 0;
            var steal_size = size - (size / 2);
            while (i < steal_size) : (i += 1) {
                const task = other.runq[(head +% i) % other.runq.len];
                self.runq[(t +% i) % self.runq.len] = task;
            }

            // try and commit the steal (against both head & tail to sync with pop*())
            _ = @cmpxchgWeak(usize, 
                @ptrCast(*usize, other.runq_head),
                (@as(usize, head) << IndexShift) | @as(usize, tail),
                (@as(usize, head +% steal_size) << IndexShift) | @as(usize, tail),
                .Release,
                .Monotonic,
            ) orelse {
                steal_size -= 1; // returning the last tasks
                if (steal_size != 0) {
                    @atomicStore(Index, &self.runq_tail, t +% steal_size, .Release);
                }
                return self.run[(t +% steal_size) % self.runq.len];
            };
        }
    }
};

pub const Task = struct {
    next: ?*Task,
    frame: usize,

    pub const Priority = enum(u1) {
        Low,
        High,
    };

    pub fn init(frame: anyframe, comptime priority: Priority) Task {
        return Task{
            .next = null,
            .frame = @ptrToInt(frame) | @enumToInt(priority);
        };
    }

    pub fn getFrame(self: Task) anyframe {
        return @intToPtr(frame, self.frame & ~@as(usize, ~@as(@TagType(Priority), 0)));
    }

    pub fn getPriority(self: Task) Priority {
        return @intToEnum(Priority, @as(@TagType(Priority), self.frame & ~FRAME_MASK));
    }

    pub const List = struct {
        head: ?*Task,
        tail: ?*Task,
        size: usize,

        pub fn push(self: *List, list: List) void {
            if (self.tail) |tail| {
                tail.next = list.head;
            }
            if (self.head == null) {
                self.head = list.head;
            }
            self.tail = list.tail;
        }

        pub fn pop(self: *List) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            if (self.head == null) {
                self.tail = null;
            }
            return task;
        }
    };
};
