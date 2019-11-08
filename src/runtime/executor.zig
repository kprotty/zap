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
        var main_node = try Node.init(self, 0, 1, workers[0..]);
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
        }

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

        Worker.current = main_worker;
        _ = async func(args);
        var main_stack: [Worker.STACK_SIZE]u8 align(Worker.STACK_ALIGN) = undefined;
        main_worker.stack = main_stack[0..];
        main_thread.run();

        self.active_workers.wait();
        for (nodes) |node| {
            while (node.thread_pool.pop()) |thread| {
                thread.wakeWith(null);
            }
        }
    }
};

pub const Node = struct {
    numa_node: u16,
    executor: *Executor,
    monitor: Thread.Monitor,
    
    workers: []*Worker,
    idle_workers: sync.BitSet,
    thread_pool: Thread.Pool,

    pub fn init(executor: *Executor, numa_node: u16, max_threads: usize, workers: []*Worker) !Node {

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
    stack: []align(std.mem.page_size) u8,

    fn wakeWith(self: *Thread, worker: ?*Worker) void {
        if (@atomicRmw(?*Worker, &self.worker, .Xchg, worker, .Release) == null)
            self.parker.unpark(@ptrCast(*const u32, &self.worker));
    }

    fn entry(pool: *Pool) !void {
        var self = Thread{
            .node = pool.node,
            .link = undefined,
            .worker = undefined,
            .parker = std.ThreadParker.init(),
            .stack = pool.current_stack,
        };
        sync.atomicStore(&pool.current_thread, &self);
        return run(&self);
    }

    fn run(self: *Thread) !void {
        // wait for the initial worker to be set
        self.parker.park(@ptrCast(*const u32, &self.worker), 0);
        if (self.worker == Monitor.WORKER)
            return Monitor.run(&self.node.monitor);

        while (self.worker) |worker| {
            worker.thread = self;
            @newStackCall(worker.stack, Worker.run, worker);

            // a task requested to block, go through the whole process
            // and try to continue running on the worker if possible.
            if (worker.blocking_task) |blocking_task| {
                self.node.monitor.block(worker, self);
                resume blocking_task.getFrame();
                if (self.node.monitor.unblock(worker, self)) {
                    worker.submit(blocking_task);
                    continue;
                }
            }

            // our worker was stolen since we blocked too long.
            // hop in the idle list in the thread pool and wait
            // to hopefully be woken up with a worker to run tasks on.
            self.worker = null;
            self.node.thread_pool.push(self);
            self.parker.park(@ptrCast(*const u32, &self.worker), 0);
        }
    }

    const Pool = struct {
        node: *Node,
        mutex: std.Mutex,
        free_list: ?*Thread,
        free_count: usize,

        stack_ptr: usize,
        stack_size: usize,
        stack_memory: []align(std.mem.page_size) u8,
        current_thread: ?*Thread,
        current_stack: []align(std.mem.page_size) u8,
        
        fn push(self: *Pool, thread: *Thread) void {
            const held = self.mutex.acquire();
            defer held.release();

            // add to the free list and decommit
            // if it wont be soon popped for a while.
            thread.link = self.free_list;
            self.free_list = thread;
            self.free_count += 1;
            if (self.free_count > self.node.workers.len)
                system.decommit(@ptrCast([*]u8, thread)[0..self.stack_size]);
        }

        fn pop(self: *Pool) !*Thread {
            const held = self.mutex.acquire();
            defer held.release();

            // first check if theres one in the free list 
            if (self.free_list) |free_thread| {
                self.free_count -= 1;
                const thread = free_thread;
                self.free_link = thread.link;
                return thread;
            }

            // none immediately free, try and allocate some stack space
            const new_ptr = self.stack_ptr - self.stack_size;
            if (new_ptr < @ptrToInt(self.stack.ptr))
                return error.OutOfMemory;
            const prev_ptr = self.stack_ptr;
            errdefer self.stack_ptr = prev_ptr;
            self.stack_ptr = new_ptr;
            self.current_stack = @ptrCast([*]align(std.mem.page_size)u8, new_ptr)[0..self.stack_size];
            
            // spawn the new thread and wait for it to relay its structure
            self.current_thread = null;
            try system.spawn(self.node.numa_node, self.current_stack, self.node, Thread.entry);
            while (@atomicLoad(?*Thread, &self.current_thread, .Acquire) == null)
                std.os.sched_yield();
            return self.current_thread.?;
        }
    };

    const Monitor = struct {
        node: *Node,
        blocking_workers: u32,
        parker: std.ThreadParker,
        is_running: std.lazyInit(void),

        const IS_BLOCKED = 1;
        const WORKER = @intToPtr(*Worker, 1);
        const MAX_BLOCK_NS = 1 * std.time.millisecond;

        /// Mark the worker as blocking under the given thread
        /// then start the monitor thread if its sleeping. 
        fn block(self: *Monitor, worker: *Worker, thread: *Thread) !void {
            worker.thread = @intToPtr(*Thread, @ptrToInt(thread) | IS_BLOCKED);
            if (@atomicRmw(u32, &self.blocking_workers, .Add, 1, .Release) == 0)
                self.parker.unpark(&self.blocking_workers);
            try self.ensureRunning();
        }
        
        /// Worker is done blocking on the thread.
        /// Try and reclaim the worker and keep running.
        /// If this fails, then the monitor thread stole our worker.
        fn unblock(self: *Monitor, worker: *Worker, thread: *Thread) bool {
            const blocked = @intToPtr(*Thread, @ptrToInt(thread) | IS_BLOCKED);
            var current = @atomicLoad(?*Thread, &worker.thread, .Monotonic);
            while (current == blocked)
                current = @cmpxchgWeak(?*Thread, &worker.thread, blocked, thread, .Monotonic, .Monotonic) orelse return true;
            return false;
        }

        fn ensureRunning(self: *Monitor) !void {
            _ = self.is_running.get() orelse {
                errdefer self.is_running.resolve();
                const monitor_thread = try self.node.thread_pool.pop();
                monitor_thread.wakeWith(Monitor.WORKER);
                return;
            };
        }

        fn run(self: *Monitor) !void {
            self.is_running.resolve();
            var timer = try std.Timer.start();
            while (@atomicLoad(usize, &self.node.executor.pending_tasks, .Monotonic) > 0) {

                // iterate all running workers with the goal of migrating them if theyre blocked too long
                const now = timer.read();
                var wait_time: u64 = MAX_BLOCK_NS * 2;
                for (self.node.workers) |*worker| {
                    const thread = @atomicLoad(?*Thread, &worker.thread, .Monotonic);
                    if ((@ptrToInt(thread) & IS_BLOCKED) != 0) {

                        // worker just started blocking, begin recording time elapsed
                        if (worker.monitor_expire == 0) {
                            worker.monitor_expire = now + MAX_BLOCK_NS;
                            wait_time = std.math.min(wait_time, MAX_BLOCK_NS);

                        // worker has been blocking over max allowed time, try and steal it to run it in another thread
                        // TODO: if @cmpxchgStrong() really needed here?
                        } else if (now >= worker.monitor_expire) {
                            worker.monitor_expire = 0;
                            const idle_thread = self.node.thread_pool.pop() orelse continue;
                            _ = @cmpxchgStrong(?*Thread, &worker.thread, thread, null, .Acquire, .Monotonic) orelse {
                                idle_thread.wakeWith(worker);
                                continue;
                            };

                        // worker is currently blocking, wait only as long as the worker closets to going over
                        } else {
                            wait_time = std.math.min(wait_time, worker.monitor_expire - now);
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
    monitor_expire: u64,
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
        if (builtin.single_threaded or self.node.workers.len == 1)
            return func(args);
        
        // wait to transition to a thread it can block on
        var task = Task.init(@frame(), .High);
        suspend {
            self.blocking_task = &task;
        }

        // perform the blocking operation then wait to
        // transition back to a non-blocking context.
        const result = func(args);
        suspend {
            task = Task.init(@frame(), .High);
        }
        return result;
    }

    pub fn submit(self: *Worker, task: *Task) void {

    }

    fn run(self: *Worker) void {
        while (@atomicLoad(usize, &self.node.executor.pending_tasks, .Monotonic) > 0) {
            self.blocking_task = null;
            resume self.findTask().getFrame();
            _ = @atomicRmw(usize, &self.node.executor.pending_tasks, .Sub, 1, .Acquire);
            if (self.blocking_task != null)
                return;
        }
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
    };

    pub fn init(frame: anyframe, comptime priority: Priority) Task {
        return Task{
            .next = null,
            .frame = @intToPtr(anyframe, @ptrToInt(frame) | @enumToInt(priority));
        };
    }

    pub fn getFrame(self: Task) anyframe {
        return @intToPtr(anyframe, @ptrToInt(self.frame) & ~usize(~@TagType(Priority)(0)));
    }

    pub fn getPriority(self: Task) Priority {
        return @intToEnum(Priority, @truncate(@TagType(Priority), @ptrToInt(self.frame)));
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
