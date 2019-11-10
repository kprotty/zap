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
    distribute_index: usize,

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
    run_queue: Worker.GlobalQueue,
    idle_workers: sync.BitSet,
    thread_pool: Thread.Pool,
    thread_monitor: Thread.Monitor,

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

    fn getStack(self: *Thread, stack_size: usize) []align(Worker.STACK_ALIGN) u8 {
        const ptr = std.mem.alignForward(@ptrToInt(self), Worker.STACK_ALIGN);
        return @intToPtr([*]align(Worker.STACK_ALIGN), ptr)[0..stack_size];
    }

    fn entry(spawn_info: *Pool.SpawnInfo) void {
        var self = Thread{
            .node = @fieldParentPtr(Node, "thread_pool", spawn_info.pool),
            .link = null,
            .worker = null,
            .parker = std.ThreadParker.init(),
        };
        sync.atomicStore(&spawn_info.thread, &self, .Release);
        spawn_info.parker.unpark(@ptrCast(*const u32, &spawn_info.thread));
        self.run();
        self.node.thread_pool.put(self);
    }

    fn run(self: *Thread) void {
        // wait to receive a worker
        self.parker.park(@ptrCast(*const u32, &self.worker), 0);
        if (self.worker == Monitor.WORKER)
            return Monitor.run(&self.node.thread_monitor);

        // run the worker as long as there is one
        while (self.worker) |worker| {
            worker.thread = self;
            if (worker.stack.len != 0) {
                @newStackCall(worker.stack, Worker.run, worker);
            } else {
                worker.run();
            }

            // a worker exiting without a blocking thread means theres no more work.
            if (!worker.is_blocking)
                return;
            worker.is_blocking = false;
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
            self.worker = null;
            self.node.thread_pool.put(self);
            self.parker.park(@ptrCast(*const u32, &self.worker), 0);
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
        
        fn block(self: *Monitor, worker: *Worker, thread: *Thread) bool {

        }

        fn unblock(self: *Monitor, worker: *Worker, thread: *Thread) bool {

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
    is_blocking: bool,
    run_tick: u32,
    run_queue: LocalQueue,
    
    pub fn init(node: *Node, stack: []align(STACK_ALIGN) u8) Worker {
        return Worker{
            .node = node,
            .thread = null,
            .stack = stack,
            .next_task = null,
            .is_blocking = false,
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
        suspend self.is_blocking = true;

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
            if (self.is_blocking)
                return;
            if (@atomicRmw(usize, &self.node.executor.pending_tasks, .Sub, 1, .Release) == 1)
                return;
        }
    }

    fn getTask(self: *Worker, blocking: bool) ?*Task {

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
