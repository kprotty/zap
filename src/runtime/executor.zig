const std = @import("std");
const builtin = @import("builtin");
const sync = @import("./sync.zig");

const system = switch (builtin.os) {
    .windows => @import("./system/windows.zig"),
    .linux => @import("./system/linux.zig"),
    .posix => @import("./system/posix.zig"),
};

pub const Executor = struct {
    nodes: []*Node,
    pending_tasks: usize,
    active_workers: sync.Barrier,
    distribute_index: usize,

    pub fn run(comptime func: var, args: ...) !void {
        var self: Executor = undefined;
        if (builtin.single_threaded)
            return self.runSequential(func, args);
        return self.runParallel(func, args);
    }

    pub fn runSequential(self: *Executor, comptime func: var, args: ...) !void {
        // setup the worker and node on the stack
        var workers = [1]Worker{ undefined };
        var main_node = try Node.init(self, 0, workers[0..], null, null, null);
        defer main_node.deinit();

        var nodes = [_]*Node{ &main_node };
        return self.runUsing(nodes, func, args);
    }

    pub fn runParallel(self: *Executor, comptime func: var, args: ...) !void {
        // store the array of node pointers on the stack.
        // since its on the stack, limit the maximum amount of numa nodes.
        // also perform the `defer` first to make sure all nodes are freed in case of error
        var node_array = [_]?*Node{null} ** BitSet.Max;
        const array = node_array[0..system.getNumaNodeCount()];
        defer for (array) |ptr| {
            if (ptr) |node|
                node.free();
        };

        // Allocate each node on its corresponding numa node for locality
        for (array) |*node, index|
            node.* = try Node.alloc(self, index, Thread.DEFAULT_MAX, null);
        const nodes = @ptrCast([*]Node, array.ptr)[0..array.len];
        return self.runUsing(nodes, func, args);
    }

    pub fn runSMP(self: *Executor, comptime func: var, args: ..., max_workers: usize, max_threads: usize) !void {
        // max_threads limits max_workers
        const num_threads = std.math.min(Thread.DEFAULT_MAX, std.math.max(1, max_threads)) - 1;
        const num_workers = std.math.min(num_threads + 1, std.math.max(1, max_workers));

        // allocate the node on the first NUMA node by default
        const node = try Node.alloc(self, 0, num_threads, num_workers);
        defer node.free();
        var nodes = [_]*Node{ &node };
        return self.runUsing(nodes[0..], func, args);
    }

    pub fn runUsing(self: *Executor, nodes: []*Node, comptime func: var, args: ...) !void {
        self.* = Executor{
            .nodes = nodes,
            .pending_tasks = 0,
            .active_workers = sync.Barrier.init(1),
            .distribute_index = 0,
        };
        
        // start with a random numa node in order to not over-subscribe on a single
        // one if theres multiple numa applications running on the system.
        const main_node = &nodes[system.getRandom().uintAtMost(usize, nodes.len)];
        const main_worker = &main_node.workers[main_node.idle_workers.get().?];
        var main_thread = Thread{
            .node = main_node,
            .link = null,
            .worker = main_worker,
            .parker = std.ThreadParker.init(),
        };

        // run the func() on the main worker then wait for all workers to complete.
        Worker.current = main_worker;
        _ = async func(args);
        try main_thread.run();
        self.active_workers.wait();
    }
};

pub const Node = struct {
    executor: *Executor,
    reactor: system.Reactor,
    workers: []Worker,
    affinity: system.CpuAffinity,
    idle_workers: sync.BitSet,
    run_queue: Worker.GlobalQueue,
    thread_monitor: Thread.Monitor,
    thread_pool: Thread.Pool,

    pub fn init(
        executor: *Executor,
        numa_node: u16,
        workers: []Worker,
        affinity: ?system.CpuAffinity,
        stack_size: ?usize,
        thread_stacks: ?[]align(Worker.STACK_ALIGN) u8,
    ) !Node {
        const stack = thread_stacks orelse @as([*]align(Worker.STACK_ALIGN) u8, undefined)[0..0];
        return Node{
            .executor = executor,
            .reactor = try system.Reactor.init(numa_node),
            .workers = workers,
            .affinity = affinity orelse try system.CpuAffinity.get(numa_node),
            .idle_workers = sync.BitSet.init(workers.len),
            .run_queue = Worker.GlobalQueue{
                .mutex = std.Mutex.init(),
                .tasks = Task.List{
                    .head = null,
                    .tail = null,
                    .size = 0,
                },
            },
            .thread_monitor = Thread.Monitor{
                .timer = undefined,
                .parker = std.ThreadParker.deinit(),
                .has_blocking = false,
                .thread = std.lazyInit(?*Thread),
            },
            .thread_pool = Thread.Pool{
                .mutex = std.Mutex.init(),
                .free_list = null,
                .free_count = 0,
                .stack_ptr = @ptrToInt(stack.ptr) + stack.len,
                .stack_size = stack_size orelse Thread.STACK_SIZE,
                .stack_list = null,
                .stack = stack,
                .exit_mutex = std.Mutex.init(),
                .exit_stack = undefined,
            },
        };
    }

    pub fn deinit(self: *Node) void {
        self.thread_monitor.deinit();
        self.thread_pool.deinit();
        self.reactor.deinit();
    }

    pub fn alloc(executor: *Executor, numa_node: u16, max_threads: usize, max_workers: ?usize) !*Node {
        var size: usize = @sizeOf(Node);
        const affinity = try system.CpuAffinity.get(numa_node);
        const stack_size = system.Thread.getStackSize(Thread.STACK_SIZE);
        const num_workers = std.math.min(affinity.getCount(), max_workers orelse ~@as(usize, 0));

        size = std.mem.alignForward(size, @alignOf(Worker));
        const worker_offset = size;
        size += num_workers * @sizeOf(Worker);

        size = std.mem.alignForward(size, Worker.STACK_ALIGN);
        const worker_stack_offset = size;
        size += num_workers * Worker.STACK_SIZE;

        size = std.mem.alignForward(size, Worker.STACK_ALIGN);
        const thread_stack_offset = size;
        size += max_threads * stack_size;

        const memory = try system.map(numa_node, size);
        errdefer system.unmap(memory);
        const ptr = @ptrToInt(memory.ptr);

        const self = @intToPtr(*Node, ptr);
        const workers = @intToPtr([*]Worker, ptr + worker_offset)[0..num_workers];
        for (workers) |*worker, index|
            worker.stack = @intToPtr([*]align(Worker.STACK_ALIGN) u8, ptr + worker_stack_offset * i)[0..Worker.STACK_SIZE];
        const stack = @intToPtr([*]align(Worker.STACK_ALIGN) u8, ptr + thread_stack_offset)[0..max_threads * stack_size];
        self.* = try Node.init(executor, numa_node, workers, affinity, stack);
        return self;
    }

    pub fn free(self: *Node) void {
        self.deinit();
        const ptr_begin = @ptrToInt(self);
        const ptr_end = @ptrToInt(self.thread_pool.stack) + self.thread_pool.stack.len;
        system.unmap(@intToPtr([*]align(std.mem.page_size) u8, ptr_begin)[0..ptr_end - ptr_begin]);
    }
};

const Thread = struct {
    const DEFAULT_MAX = 10 * 1000;
    const PTHREAD_STACK_MIN = 16 * 1024;
    const STACK_SIZE = if (builtin.os == .windows)
        0
    else if (builtin.link_libc)
        PTHREAD_STACK_MIN
    else
        std.mem.alignForward(std.mem.page_size + @sizeOf(@Frame(Thread.entry)), std.mem.page_size);

    node: *Node,
    link: ?*Thread,
    worker: ?*Worker,
    should_exit: bool,
    parker: std.ThreadParker,

    fn getStack(self: *Thread, stack_size: usize) []align(Worker.STACK_ALIGN) u8 {
        const ptr = std.mem.alignForward(@ptrToInt(self), Worker.STACK_ALIGN);
        return @intToPtr([*]align(Worker.STACK_ALIGN), ptr)[0..stack_size];
    }

    fn wakeWith(self: *Thread, worker: ?*Worker) void {
        if (@atomicRmw(?*Worker, &self.worker, .Xchg, worker, .Release) == null)
            self.parker.unpark(@ptrCast(*const u32, &self.worker));
    }

    fn entry(spawn_info: *Pool.SpawnInfo) void {
        var self = Thread{
            .node = @fieldParentPtr(Node, "thread_pool", spawn_info.pool),
            .link = null,
            .worker = null,
            .should_exit = false,
            .parker = std.ThreadParker.init(),
        };
        sync.atomicStore(&spawn_info.thread, &self, .Release);
        spawn_info.parker.unpark(@ptrCast(*const u32, &spawn_info.thread));
        system.Thread.setAffinity(self.node.affinity);
        self.run();
        if (!self.should_exit)
            self.node.thread_pool.put(self);
    }

    fn run(self: *Thread) void {
        // wait to receive a worker
        self.parker.park(@ptrCast(*const u32, &self.worker), 0);
        if (self.worker == Monitor.WORKER)
            return Monitor.run(&self.node.thread_monitor, self);

        // run the worker as long as there is one
        while (self.worker) |worker| {
            worker.thread = self;
            if (worker.stack.len != 0) {
                @newStackCall(worker.stack, Worker.run, worker);
            } else {
                worker.run();
            }

            // a worker exiting without a blocking thread means theres no more work.
            if (!worker.will_block)
                return;
            worker.will_block = false;
            const blocking_task = worker.next_task orelse return;

            // only consume the blocking task if actually allowed to block.
            // if able to reclaim worker, then go back to running the blocking task on the worker.
            if (!self.node.thread_monitor.block(worker, self))
                continue;
            worker.next_task = null;
            resume blocking_task.getFrame();
            if (self.node.thread_monitor.unblock(worker, self)) {
                worker.next_task = blocking_task;
                continue;
            }

            // not able to reclaim the current worker, try and find a new one
            if (self.node.idle_workers.get()) |idle_worker_index| {
                const idle_worker = &self.node.workers[idle_worker_index];
                idle_worker.next_task = blocking_task;
                self.worker = idle_worker;
                continue;
            }

            // no free workers. stop the thread until were signaled with one
            self.worker = @intToPtr(*Worker, 2);
            self.node.thread_pool.put(self);
            self.parker.park(@ptrCast(*const u32, &self.worker), 2);
        }
    }

    const Pool = struct {
        mutex: std.Mutex,
        free_list: ?*Thread,
        free_count: usize,
        stack_ptr: usize,
        stack_size: usize,
        stack_list: ?*Thread,
        stack: []align(Worker.STACK_ALIGN) u8,
        exit_mutex: std.Mutex,
        exit_stack: [@sizeOf(@Frame(Thread.exit))]u8 align(16),

        fn deinit(self: *Pool) void {
            const held = self.mutex.acquire();
            defer held.release();
            defer self.mutex.deinit();

            const exit_held = self.exit_mutex.acquire();
            defer exit_held.release();
            defer self.exit_mutex.deinit();

            while (self.free_list) |free_thread| {
                defer self.free_list = free_thread.link;
                free_thread.should_exit = true;
                free_thread.wakeWith(null);
            }
        }

        fn exit(self: *Pool, thread: *Thread, exit_held: std.Mutex.Held) void {
            thread.parker.deinit();
            system.decommit(thread.getStack());
            exit_held.release();
            system.Thread.exit(); // MUST be thread-safe since the exit lock is released.
        }

        fn put(self: *Pool, thread: *Thread) void {
            const held = self.mutex.acquire();
            const node = @fieldParentPtr(Node, "thread_pool", self);

            // if theres enough threads to service blocking workers,
            // this one should not be cached and exit to save memory.
            if (self.free_count > node.workers.len) {
                thread.link = self.stack_list;
                self.stack_list = thread;
                held.release();
                if (self.stack_size > 0) {
                    const exit_held = self.exit_mutex.acquire();
                    @newStackCall(self.exit_stack, Thread.exit, self, thread, exit_held);
                }
            }

            // the free_list is a bit empty to add it there
            thread.link = self.free_list;
            self.free_list = thread;
            self.free_count += 1;
            held.release();
        }

        const SpawnInfo = struct {
            pool: *Pool,
            thread: ?*Thread,
            parker: std.ThreadParker,
        };

        fn get(self: *Pool) ?*Thread {
            const held = self.mutex.acquire();
            defer held.release();

            // first, try and pop from the free list
            if (self.free_list) |thread| {
                const free_thread = thread;
                self.free_list = thread.link;
                self.free_count -= 1;
                return free_thread;
            }

            // new thread needed, try and allocate stack space for it.
            // check the free stack_list first, then try to raw alloc if empty.
            var stack: []align(Worker.STACK_ALIGN) u8 = undefined;
            var is_new_stack = false;
            if (self.stack_size > 0) {
                if (self.stack_list) |free_stack_thread| {
                    stack = free_stack_thread.getStack();
                    self.stack_list = free_stack_thread.link;
                } else {
                    const new_ptr = self.stack_ptr - self.stack_size;
                    if (new_ptr < @ptrToInt(self.stack.ptr))
                        return null;
                    is_new_stack = true;
                    stack = @intToPtr([*]align(Worker.STACK_ALIGN) u8, new_ptr)[0..self.stack_size];
                }
            }

            // then spawn the thread, wait to get its *Thread pointer and return it.
            var spawn_info = SpawnInfo{
                .pool = self,
                .thread = null,
                .parker = std.ThreadParker.init(),
            };
            defer spawn_info.parker.deinit();
            system.Thread.spawn(stack, &spawn_info, Thread.entry) catch return null;
            spawn_info.parker.park(@ptrCast(*const u32, &spawn_info.thread), 0);
            if (is_new_stack) // commit stack alloc only if successful in spawning the thread
                self.stack_ptr = @ptrToInt(stack.ptr);
            return spawn_info.thread;
        }
    };
    
    const Monitor = struct {
        timer: std.time.Timer,
        parker: std.ThreadParker,
        has_blocking: bool align(@alignOf(u32)),
        thread: @typeOf(std.lazyInit(?*Thread)),
        
        const IS_BLOCKED: usize = 0x1;
        const WORKER = @intToPtr(*Worker, 0x1);
        const MAX_BLOCK_NS = 2 * std.time.millisecond;

        fn deinit(self: *Monitor) void {
            if (self.thread.get()) |thread_ptr| {
                const monitor_thread = thread_ptr.* orelse return;
                monitor_thread.should_exit = true;
                self.notifyBlocking();
            } else {
                self.thread.data = null;
                self.thread.resolve();
            }
        }

        fn notifyBlocking(self: *Monitor) void {
            const has_blocking_ptr = @ptrCast(*u32, &self.has_blocking);
            if (@atomicRmw(u32, has_blocking_ptr, .Xchg, @boolToInt(true), .Release) == @boolToInt(false))
                self.parker.unpark(has_blocking_ptr);
        }

        fn block(self: *Monitor, worker: *Worker, thread: *Thread) bool {
            // should only block if theres a monitor thread running to potentially unblock us.
            if (!self.ensureMonitoring())
                return false;

            // setup the worker into a blocking state
            const expires = @truncate(usize, self.timer.read());
            const blocked = @intToPtr(*Thread, @ptrToInt(thread) | IS_BLOCKED);
            sync.atomicStore(&worker.thread, blocked, .Monotonic);
            sync.atomicStore(&worker.monitor_expires, expires + MAX_BLOCK_NS, .Monotonic);

            // notify the monitor thread that theres a new blocking worker
            self.notifyBlocking();
            return true;
        }

        fn unblock(self: *Monitor, worker: *Worker, thread: *Thread) bool {
            // try and take back our worker after blocking.
            // if we fail, the monitor thread stole our worker.
            // if so, wait for the monitor thread to complete the steal and return whether it was successfull.
            const blocked = @intToPtr(*Thread, @ptrToInt(thread) | IS_BLOCKED);
            if (@cmpxchgWeak(?*Thread, &worker.thread, blocked, thread, .Acquire, .Monotonic) != null) {
                thread.parker.park(@ptrCast(*const u32, &worker.thread), 0);
                return @atomicLoad(?*Thread, &worker.thread, .Acquire) == thread;
            }

            // we managed to take back our worker, so continue running.
            sync.atomicStore(&worker.monitor_expires, 0, .Monotonic);
            return true;
        }

        fn ensureMonitoring(self: *Monitor) bool {
            // globally once-init the monitor thread.
            // assume null until successfully initialized.
            if (self.thread.get()) |thread_ptr|
                return thread_ptr.* != null;
            defer self.thread.resolve();
            self.thread.data = null;
            
            // begin the timer & start up a monitor thread
            self.timer = std.time.Timer.start() catch return false;
            const node = @fieldParentPtr(Node, "thread_monitor", self);
            const monitor_thread = node.thread_pool.get() orelse return false;
            self.thread.data = monitor_thread;
            monitor_thread.wakeWith(Monitor.WORKER);
            return true;
        }

        fn run(self: *Monitor, thread: *Thread) void {
            // keep running while the executor is up.
            // the goal of each iteration is to steal workers who are blocked on a thread
            const node = @fieldParentPtr(Node, "thread_monitor", self);
            while (!thread.should_exit) {
                const now = self.timer.read();
                var wait_time = ~@as(usize, 0);

                // iterate through all the workers that are blocked
                for (nodes.workers) |*worker| {
                    const thread = @atomicLoad(?*Thread, &worker.thread, .Monotonic);
                    if ((@ptrToInt(thread) & IS_BLOCKED) != 0) {
                        const expires = @atomicLoad(usize, &worker.monitor_expires, .Monotonic);

                        // worker is not blocked
                        if (expires == 0)
                            continue;

                        // worker is blocked, but not over max block time
                        if (expires < now) {
                            wait_time = std.math.min(wait_time, expires);
                            continue;
                        }

                        // Worker is blocked AND over max block time so try and steal it from the blocking thread.
                        // Once done trying to steal, notify the blocked thread of the attempt.
                        // a `worker.thread` of the blocked thread means the steal was unsuccessful.
                        if (@cmpxchgWeak(?*Thread, &worker.thread, thread, null, .Acquire, .Monotonic) != null)
                            continue;
                        sync.atomicStore(&worker.monitor_expires, 0, .Monotonic);
                        var next_thread = @intToPtr(?*Thread, @ptrToInt(thread) & ~IS_BLOCKED);
                        defer {
                            sync.atomicStore(&worker.thread, next_thread, .Release);
                            thread.parker.unpark(@ptrCast(*const u32, &worker.thread));
                        };

                        // Only migrate the worker from the thread if:
                        // - theres a task that needs to be processed on the worker
                        // - theres a free thread for the worker to process that task.
                        const idle_task = worker.getTask(false) orelse continue;
                        const idle_thread = node.thread_pool.get() orelse continue;
                        worker.next_task = idle_task;
                        next_thread = idle_thread;
                        idle_thread.wakeWith(worker);
                    }
                }

                // re-scan the workers if a new one has started blocking
                const has_blocking_ptr = @ptrCast(*u32, &self.has_blocking);
                if (@atomicRmw(u32, has_blocking_ptr, .Xchg, @boolToInt(false), .Release) == @boolToInt(true))
                    continue;
                
                // sleep until a blocking worker's max block time expires
                if (wait_time != ~@as(usize, 0)) {
                    std.time.sleep(wait_time);
                    continue;
                }

                // no blocking workers, wait until there is one
                self.parker.park(has_blocking_ptr, @boolToInt(false));
            }
        }
    };
};

pub const Worker = struct {
    pub threadlocal var current: ?*Worker= null;

    const STACK_ALIGN = if (builtin.os == .windows) 0 else std.mem.page_size;
    const STACK_SIZE = switch (builtin.os) {
        .windows => 0, // windows doesnt allow custom thread stacks
        else => switch (@typeInfo(usize).Int.bits) {
            64 => 4 * 1024 * 1024,
            32 => 1 * 1024 * 1024,
            else => @compileError("Architecture not supported"),
        },
    };

    node: *Node,
    thread: ?*Thread,
    stack: []align(STACK_ALIGN) u8,
    
    next_task: ?*Task,
    will_block: bool,
    monitor_expires: usize,
    run_tick: u32,
    run_queue: LocalQueue,
    
    pub fn init(node: *Node, stack: []align(STACK_ALIGN) u8) Worker {
        return Worker{
            .node = node,
            .thread = null,
            .stack = stack,
            .next_task = null,
            .will_block = false,
            .monitor_expires = 0,
            .run_tick = 0,
            .run_queue = LocalQueue{
                .head = 0,
                .tail = 0,
                .tasks = undefined,
            },
        };
    }

    pub fn bumpPending(self: *Worker) void {
        _ = @atomicRmw(usize, &self.node.executor.pending_tasks, .Add, 1, .Release);
    }

    pub fn blocking(self: *Worker, comptime func: var, args: ...) @typeOf(func).ReturnType {
        // skips possibly spawning a thread if running sequentially
        if (builtin.single_threaded or self.node.workers.len == 1)
            return func(args);
        
        // wait for the async function to get into a blocking context
        var task = Task.init(@frame(), .High);
        self.submit(task);
        suspend self.will_block = true;

        // perform the blocking function,
        // wait to get back into a non-blocking context,
        // then return the result of the blocking operation.
        const result = func(args);
        suspend task = Task.init(@frame(), .Local);
        return result;
    }

    fn tryDistribute(node: *Node, task: *Task) bool {
        const idle_worker_index = node.idle_workers.get() orelse return false;
        const idle_thread = node.thread_pool.get() orelse {
            node.idle_workers.set(idle_worker_index);
            return false;
        };
        const idle_worker = &node.worers[idle_worker_index];
        idle_worker.next_task = task;
        idle_thread.wakeWith(idle_worker);
        return true;
    }

    pub fn submit(self: *Worker, task: *Task) void {
        // first, try and distribute it to other Workers on the current node
        if (tryDistribute(self.node, task))
            return;
        
        // then try and distribute the task according to its priority
        switch (task.getPriority()) {
            .Low => {
                self.run_queue.pushBack(task);
            },
            .High => {
                const old_next = self.next_task;
                self.next_task = task;
                if (old_next) |next_task|
                    self.run_queue.pushFront(next_task);
            },
            .Local => {
                self.node.run_queue.put(task);
            },
            .Global => {
                const node_index = @atomicRmw(usize, &self.node.executor.distribute_index, .Add, 1, .Monotonic);
                const next_node = self.node.executor.nodes[node_index % self.node.executor.nodes.len];
                if (!tryDistribute(next_node, task))
                    next_node.run_queue.put(task);
            },
        }
    }

    fn run(self: *Worker) void {
        while (@atomicLoad(usize, &self.node.executor.pending_tasks, .Monotonic) > 0) {
            const task = self.getTask(true) orelse return;
            resume task.getFrame();
            if (self.will_block)
                return;
            if (@atomicRmw(usize, &self.node.executor.pending_tasks, .Sub, 1, .Release) == 1)
                return;
        }
    }

    fn getTask(self: *Worker, blocking: bool) ?*Task {
        const LOW_PRIORITY_TICK = 7;
        const LOCAL_PRIORITY_TICK = 61;
        self.run_tick +%= 1;

        // check our node's global_queue once in a while
        if ((self.run_tick % LOCAL_PRIORITY_TICK) == 0) {
            if (self.node.run_queue.get(&self.run_queue)) |task|
                return task;

        // pop from the back once in a while to ensure fairness (FIFO)
        } else if ((self.run_tick % LOW_PRIORITY_TICK) == 0) {
            if (self.run_queue.popBack()) |task|
                return task;

        // check the next_task slot if its set
        } else if (self.next_task) |next_task| {
            const task = next_task;
            self.next_task = null;
            return task;

        // most common: pop from the front (LIFO)
        } else if (self.run_queue.popFront()) |task| {
            return task;

        // local queue is empty, check our node's global queue
        } else if (self.node.run_queue.get(&self.run_queue)) |task| {
            return task;

        // our node's global queue is empty. try polling the reactor for some tasks
        } else if (self.pollReactor()) |task| {
            return task;
        }

        // now we should try to steal from other workers in the other of:
        // - the run_queue of the workers on our local node
        // - our local node's run_queue
        // - the run_queue of the workers on other nodes
        // - other node's run_queue
        // - finally, our local node again

        // if not `blocking`, return null here 
        // then block on pollReactor() or set the worker to idle & release the thread
    }

    const GlobalQueue = struct {
        mutex: std.Mutex,
        tasks: Task.List,
    };

    const LocalQueue = struct {
        head: u32,
        tail: u32,
        tasks: [256]*Task = undefined,

        // for Task.Priority.High
        fn pushFront(self: *LocalQueue, task: *Task) void {

        }

        // for Task.Priority.low
        fn pushBack(self: *LocalQueue, task: *Task) void {

        }

        fn popFront(self: *LocalQueue) ?*Task {

        }

        fn popBack(self: *LocalQueue) ?*Task {

        }

        fn steal(noalias self: *LocalQueue, noalias other: *LocalQueue) ?*Task {

        }
    };
};

pub const Task = struct {
    next: ?*Task,
    frame: anyframe,
    
    pub const Priority = enum(u2) {
        /// Schedule to end of the local queue on the current node
        Low,
        /// Schedule to the front of the local queue on the current node
        High,
        /// Schedule into the global or local queue on the current node
        Local,
        /// Schedule into the global or local queue on any node in the executor
        Global,
    };

    pub fn init(frame: anyframe, comptime priority: Priority) Task {
        return Task{
            .next = null,
            .frame = @intToPtr(anyframe, @ptrToInt(frame) | @enumToInt(priority)),
        };
    }

    pub fn getFrame(self: Task) anyframe {
        const frame_mask = ~@as(usize, ~@as(@TagType(Priority), 0));
        return @intToPtr(anyframe, @ptrToInt(self.frame) & frame_mask);
    }

    pub fn setFrame(self: *Task, frame: anyframe) void {
        const priority = @ptrToInt(self.frame) & ~@as(@TagType(Priority), 0);
        self.frame = @intToPtr(anyframe, @ptrToInt(frame) | priority);
    }

    pub fn getPriority(self: Task) Priority {
        return @intToEnum(Priority, @truncate(@TagType(Priority), @ptrToInt(self.frame)));
    }

    pub fn setPriority(self: *Task, comptime priority: Priority) void {
        self.frame = @intToPtr(anyframe, @ptrToInt(self.getFrame()) | @enumToInt(priority));
    }

    pub const List = struct {
        size: usize,
        head: ?*Task,
        tail: ?*Task,
        
        pub fn push(self: *List, list: List) void {
            if (self.tail) |tail|
                tail.next = list.head;
            self.tail = list.tail;
            if (self.head == null)
                self.head = list.head;
            self.size += list.size;
        }

        pub fn pop(self: *List) ?*Task {
            const head = self.head orelse return null;
            self.head = head.next;
            if (self.head == null)
                self.tail = null;
            return head;
        }
    };
};
