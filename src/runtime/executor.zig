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
    idle_nodes: sync.BitSet,
    pending_tasks: usize,
    active_workers: sync.Barrier,

    pub fn run(comptime func: var, args: ...) !void {
        var self: Executor = undefined;
        if (builtin.single_threaded)
            return self.runSequential(func, args);
        return self.runParallel(func, args);
    }

    pub fn runSequential(self: *Executor, comptime func: var, args: ...) !void {
        // setup the worker on the stack
        var main_worker: Worker = undefined;
        var workers = [_]*Worker{ &main_worker };

        // setup the node on the stack
        var main_node = try Node.init(self, 0, workers[0..], 0);
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
            node.* = try Node.alloc(self, index, 1024);
        const nodes = @ptrCast([*]Node, array.ptr)[0..array.len];
        return self.runUsing(nodes, func, args);
    }

    pub fn runUsing(self: *Executor, nodes: []*Node, comptime func: var, args: ...) !void {
        self.* = Executor{
            .nodes = nodes,
            .idle_nodes = sync.BitSet.init(nodes.len),
            .pending_tasks = 0,
            .active_workers = sync.Barrier.init(1),
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

        // ensure all the idle threads get signaled to stop
        defer for (nodes) |*node| {
            while (node.thread_pool.pop()) |thread| {
                thread.wakeWith(null);
            }
        };

        // run the func() on the main worker then wait for all workers to complete.
        Worker.current = main_worker;
        _ = async func(args);
        try main_thread.run();
        self.active_workers.wait();
    }
};

pub const Node = struct {
    numa_node: u16,
    executor: *Executor,
    
    workers: []*Worker,
    idle_workers: sync.BitSet,
    thread_pool: Thread.Pool,
    monitor: Thread.Monitor,

    pub fn init(executor: *Executor, numa_node: u16, workers: []*Worker, max_threads: usize) !Node {

    }

    pub fn deinit(self: *Node) void {

    }

    pub fn alloc(executor: *Executor, numa_node: u16, max_threads: usize) !*Node {

    }

    pub fn free(self: *Node) void {

    }

};

const Thread = struct {
    node: *Node,
    link: ?*Thread,
    worker: ?*Worker,
    parker: std.ThreadParker,
    is_running: bool align(@alignOf(u32)),

    fn wakeWith(self: *Thread, worker: ?*Worker) void {
        if (@atomicRmw(?*Worker, &self.worker, .Xchg, worker, .Release) == null)
            self.parker.unpark(@ptrCast(*const u32, &self.worker));
    }

    fn entry(spawn_info: *Pool.SpawnInfo) noreturn {
        var self = Thread{
            .node = spawn_info.pool.node,
            .link = undefined,
            .worker = undefined,
            .parker = std.ThreadParker.init(),
            .is_running = true,
        };
        sync.atomicStore(&spawn_info.pool.thread, &self);
        self.parker.park(@ptrCast(*const u32, &self.worker), 0);

        if (self.worker == Monitor.WORKER) {
            Monitor.run(&self.node.monitor);
        } else {
            self.run();
        }
        return system.Thread.exit();
    }

    fn run(self: *Thread) void {
        while (self.worker) |worker| {
            worker.thread = self;
            if (worker.stack.len != 0) {
                @newStackCall(worker.stack, Worker.run, worker);
            } else {
                worker.run();
            }

            // a task requested to block, go through the whole process
            // and try to continue running on the worker if possible.
            // Re-queue the task if the monitor thread isnt able to be started up.
            if (worker.blocking_task) |blocking_task| {
                const task = blocking_task;
                worker.blocking_task = null;
                const is_blocking = self.node.monitor.block(worker, self);
                resume task.getFrame();
                if (!is_blocking or (is_blocking and self.node.monitor.unblock(worker, self))) {
                    worker.submit(task);
                    continue;
                }
            }

            // our worker was stolen since we blocked too long.
            // try and become reusable in the thread-pool or
            // exit if the pool is full to save memory.
            self.worker = null;
            if (!self.node.thread_pool.put(self))
                return;
            self.parker.park(@ptrCast(*const u32, &self.worker), 0);
        }
    }

    const Pool = struct {
        node: *Node,
        mutex: std.Mutex,
        free_list: FreeList,
        
        /// Mark the thread as idle by trying to put it in the free list
        /// Returns false if the free_list is full and the thread should exist instead. 
        fn put(self: *Pool, thread: *Thread) bool {
            const held = self.mutex.acquire();
            defer held.release();

            // TODO
        }

        /// Get a free thread to run a worker on.
        /// First check the free_list then try to allocate/create a new one.
        fn get(self: *Pool) ?*Thread {
            const held = self.mutex.acquire();
            defer held.release();

            // TODO
        }
    };

    const Monitor = struct {
        node: *Node,
        timer: std.Timer,
        blocking_workers: u32,
        parker: std.ThreadParker,
        is_running: @typeOf(std.lazyStatic(bool)),
        
        const IS_BLOCKED = 1;
        const WORKER = @intToPtr(*Worker, 1);
        const MAX_BLOCK_NS = 10 * std.time.millisecond;

        fn ensureRunning(self: *Monitor) bool {
            // guard initialization & assume is_running is false on error
            if (self.is_running.get()) |is_running_ptr|
                return is_running_ptr.*;
            defer self.is_running.resolve();
            self.is_running.data = false;

            // grab a thread for monitoring, start the timer, and set is_running.
            const monitor_thread = self.node.thread_pool.get() orelse return false;
            self.timer = std.Timer.start() orelse return false;
            monitor_thread.wakeWith(Monitor.WORKER);
            self.is_running.data = true;
            return true;
        }

        /// Mark the worker as blocking under the given thread
        /// then start the monitor thread if its sleeping.
        /// Returns whether or not theres a monitor thread that can unblock this thread.
        fn block(self: *Monitor, worker: *Worker, thread: *Thread) bool {
            if (!self.ensureRunning())
                return false;

            const expires = @truncate(usize, self.timer.read() + MAX_BLOCK_NS);
            sync.atomicStore(&worker.monitor_expire, expires, .Monotonic);
            const blocked = @intToPtr(*Thread, @ptrToInt(thread) | IS_BLOCKED);
            sync.atomicStore(&worker.thread, blocked, .Monotonic);

            if (@atomicRmw(u32, &self.blocking_workers, .Add, 1, .Release) == 0)
                self.parker.unpark(&self.blocking_workers);
            return true;
        }
        
        /// Worker is done blocking on the thread.
        /// Try and reclaim the worker and keep running.
        /// Returns false if the monitor thread stole our worker.
        fn unblock(self: *Monitor, worker: *Worker, thread: *Thread) bool {
            // assume non-null because should have been resolved by a call to block() first.
            // test this first to avoid the cmpxchg (write) below.
            if (!self.is_running.get().?.*)
                return true;

            var spin = std.SpinLock.Backoff.new();
            var current = @atomicLoad(?*Thread, &worker.thread, .Monotonic);
            const blocked = @intToPtr(*Thread, @ptrToInt(current) | IS_BLOCKED);
            while (current == blocked) : (spin.yield()) {
                current = @cmpxchgWeak(?*Thread, &worker.thread, blocked, thread, .Release, .Monotonic) orelse {
                    sync.atomicStore(&worker.monitor_expire, 0, .Monotonic);
                    return true;
                };
            }
            return false;
        }

        fn run(self: *Monitor) void {
            while (@atomicLoad(usize, &self.node.executor.pending_tasks, .Monotonic) == 0) {
                const now = timer.read();
                var wait_time: u64 = MAX_BLOCK_NS * 2;

                // iterate all running workers with the goal of migrating them if theyre blocked on threads too long
                for (self.node.workers) |*worker| {
                    const thread = @atomicLoad(?*Thread, &worker.thread, .Monotonic);
                    if ((@ptrToInt(thread) & IS_BLOCKED) != 0) {
                        const expires = @atomicLoad(usize, &worker.monitor_expire, .Monotonic);

                        // worker isnt blocking
                        if (expires == 0)
                            continue;
                        
                        // worker is blocking, but not over max block time
                        if (expires > now) {
                            wait_time = std.math.min(wait_time, expires - now);
                            continue;
                        }

                        // worker is blocking and over the max block time so try and steal it. only steal if:
                        // - theres another task to be processed
                        // - theres an extra thread to process that task on
                        // - the blocking thread didnt take back ownership of the worker (cmpxchg)
                        const idle_task = worker.getTask(false) orelse continue;
                        var stole_worker = false;
                        defer if (!stole_worker) {
                            worker.submit(idle_task);
                        };
                        const idle_thread = self.node.thread_pool.get() orelse continue;
                        if (@cmpxchgWeak(?*Thread, &worker.thread, thread, null, .Acquire, .Monotonic) == null) {
                            worker.blocking_workers = idle_task;
                            idle_thread.wakeWith(worker);
                            stole_worker = true;
                        } else if (!self.node.thread_pool.put(idle_thread)) {
                            idle_thread.wakeWith(null);
                        }
                    }
                }

                // - reiterate if theres new incoming blocked workers
                // - sleep for a calculated amount of time if theres blocked workers about to expire
                // - if no worker is blocked, sleep indefinitely until one does to start tracking it.
                if (@atomicRmw(u32, &self.blocking_workers, .Xchg, 0, .Acquire) > 0) {
                    continue;
                } else if (wait_time < max_block_ns * 2) {
                    std.time.sleep(wait_time);
                    continue;
                } else {
                    self.parker.park(&self.blocking_workers, 0);
                }
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
    monitor_expire: usize,
    blocking_task: ?*Task,

    run_tick: u32,
    run_queue: LocalQueue,
    stack: []align(STACK_ALIGN) u8,

    pub fn init(node: *Node, stack: []align(STACK_ALIGN) u8) Worker {
        return Worker{
            .node = node,
            .thread = null,
            .blocking_task = null,
            .run_tick = 0,
            .run_queue = LocalQueue{},
            .stack = stack,
        };
    }

    pub fn bumpPending(self: *Worker) void {
        _ = @atomicRmw(usize, &self.node.executor.pending_tasks, .Add, 1, .Release);
    }

    pub fn blocking(self: *Worker, comptime func: var, args: ...) @typeOf(func).ReturnType {
        // skips possibly spawning a thread if running sequentially
        if (builtin.single_threaded or self.node.workers.len == 1)
            return func(args);
        
        // wait to transition to a thread it can block on
        var task = Task.init(@frame(), .Override);
        suspend self.blocking_task = &task;

        // perform the blocking operation then wait to
        // transition back to a non-blocking context.
        const result = func(args);
        suspend task.setFrame(@frame());
        return result;
    }

    pub fn submit(self: *Worker, task: *Task) void {
        // TODO: take into account task priority for scheduling it
    }

    fn run(self: *Worker) void {
        while (@atomicLoad(usize, &self.node.executor.pending_tasks, .Monotonic) > 0) {
            const next_task = self.blocking_task;
            self.blocking_task = null;
            if (next_task orelse self.getTask(true)) |task|
                resume task.getFrame();
            _ = @atomicRmw(usize, &self.node.executor.pending_tasks, .Sub, 1, .Acquire);
            if (self.blocking_task != null)
                return;
        }
    }

    fn getTask(self: *Worker, blocking: bool) ?*Task {

    }

    const GlobalQueue = struct {
        mutex: std.Mutex = std.Mutex.init(),
        tasks: Task.List = Task.List{},
    };

    const LocalQueue = struct {
        head: u32 = 0,
        tail: u32 = 0,
        tasks: [256]*Task = undefined,

        
    };
};

pub const Task = struct {
    next: ?*Task = null,
    frame: anyframe = undefined,
    
    pub const Priority = enum(u2) {
        /// Schedule to end of the local queue on the current node
        Low,
        /// Schedule to the front of the local queue on the current node
        High,
        /// Distribute to other workers or nodes
        Root,
        /// Should immediately be run next (over all priorities)
        /// TODO: re-evaluate this
        Override,
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
        size: usize = 0,
        head: ?*Task = null,
        tail: ?*Task = null,
        
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
