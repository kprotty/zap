const std = @import("std");
const builtin = @import("builtin");
const min = std.math.min;
const max = std.math.max;

const sync = @import("./sync.zig");
const system = @import("./system.zig");

pub const Executor = struct {
    nodes: []*Node,
    next_node: u32,
    active_workers: u32,
    active_tasks: usize,

    pub fn run(comptime entry: var, args: ...) !void {
        if (builtin.single_threaded)
            return runSequential(entry, args);
        return runParallel(entry, args);
    }

    pub fn runSequential(comptime entry: var, args: ...) !void {
        var workers = [_]Worker{undefined};
        var node = Node.init(workers[0..], null);
        defer node.deinit();
        var nodes = [_]*Node{ &node };
        return runUsing(nodes[0..], entry, args);
    }

    pub fn runParallel(comptime entry: var, args: ...) !void {
        if (builtin.single_threaded)
            @compileError("--single-threaded doesn't support parallel execution");
        
        // store the node array on the stack to avoid generic heap alloc
        var node_array = [_]?*Node{null} ** 64;
        const node_count = min(system.getNodeCount(), node_array.len);
        const nodes = @ptrCast([*]*Node, &node_array[0])[0..node_count];

        // have the defer before the alloc to free previous nodes on error
        defer for (node_array[0..node_count]) |*node_ptr| {
            if (node_ptr.*) |node|
                node.free();
        };

        // allocate the nodes on their designated NUMA nodes
        for (nodes) |*node_ptr, index|
            node_ptr.* = try Node.alloc(index, null, null);
        return runUsing(nodes, entry, args);
    }

    pub fn runSMP(max_workers: usize, max_threads: usize, comptime entry: var, args: ...) !void {
        const node = try Node.alloc(0, max_workers, max_threads);
        defer node.free();
        var nodes = [_]*Node{ node };
        return runUsing(nodes[0..], entry, args);
    }

    pub fn runUsing(nodes: []*Node, comptime entry: var, args: ...) !void {
        var executor = Executor{
            .nodes = nodes,
            .next_node = 0,
            .active_workers = 0,
            .active_tasks = 0,
        };
        for (nodes) |node|
            node.executor = &executor;

        var main_task: Task = undefined;
        _ = async Task.prepare(&main_task, entry, args);
        
        // use a random node as main in order to avoid over-subscription
        // on one NUMA node in case theres multiple zap programs running on the system.
        const main_node = nodes[system.getRandom().uintAtMost(usize, nodes.len)];
        const main_worker = &main_node.workers[main_node.idle_workers.get().?];
        main_worker.submit(&main_task);
        main_worker.run();
    }
};

pub const Node = struct {
    executor: *Executor,
    workers: []Worker,
    idle_workers: sync.BitSet,
    thread_pool: Thread.Pool,
    thread_mutex: std.Mutex align(sync.CACHE_LINE),
    
    pub fn init(workers: []Worker, stacks: ?[]align(Thread.STACK_ALIGN) u8) !Node {
        return Node{
            .executor = undefined,
            .workers = workers,
            .idle_workers = sync.BitSet.init(workers.len),
            .thread_pool = Thread.Pool.init(stacks, @intCast(u16, workers.len)),
            .thread_mutex = std.Mutex.init(),
        };
    }

    pub fn deinit(self: *Node) void {
        self.thread_pool.deinit();
        self.* = undefined;
    }

    pub fn alloc(numa_node: u32, max_workers: ?usize, max_threads: ?usize) !*Node {
        const affinity = try system.Affinity.fromNode(numa_node);
        const num_threads = max(1, max_threads orelse Thread.DEFAULT_THREADS);
        const num_workers = max(1, min(num_threads, max_workers orelse affinity.count()));

        // get the node offset
        var size: usize = 0;
        const node_offset = size;
        size += @sizeOf(Node);

        // get the worker array offset
        size = std.mem.alignForward(size, @alignOf(Worker));
        const worker_offset = size;
        size += @sizeOf(Worker) * num_workers;

        // get the worker stack offset
        size = std.mem.alignForward(size, Worker.STACK_ALIGN);
        const worker_stack_offset = size;
        size += Worker.STACK_SIZE * num_workers;

        // get the thread stack offset if custom thread stacks are supported
        var thread_stack_offset: ?usize = null;
        if (system.Thread.USES_CUSTOM_STACKS) {
            size = std.mem.alignForward(size, Thread.STACK_ALIGN);
            thread_stack_offset = size;
            size += Thread.STACK_SIZE * num_threads;
        }

        // allocate the memory on the given NUMA node
        const memory = try system.map(numa_node, size);
        errdefer system.umap(memory);
        const ptr = @ptrToInt(memory.ptr);
        
        // compute the node, worker, and worker stacks from the memory
        const self = @intToPtr(*Node, ptr + node_offset);
        const workers = @intToPtr([*]Worker, ptr + worker_offset)[0..num_workers];
        for (workers) |*worker, index| {
            const stack_ptr = ptr + worker_stack_offset + (index * Worker.STACK_SIZE);
            worker.stack_ptr = @intToPtr([*]align(Worker.STACK_ALIGN) u8, stack_ptr);
        }

        // compute the thread stacks from the memory
        var stacks: ?[]align(Thread.STACK_ALIGN) u8 = null;
        if (thread_stack_offset) |offset| {
            const stacks_size = Thread.STACK_SIZE * num_threads;
            stacks = @intToPtr([*]align(Thread.STACK_ALIGN), ptr + offset)[0..stacks_size];
        }

        // initialize the Node using the allocated memory
        self.* = try Node.init(workers, stacks);
        return self;
    }

    pub fn free(self: *Node) void {
        // compute the end pointer of the Node's mapped memory
        var end_ptr = @ptrToInt(self.workers[self.workers.len-1].stack_ptr) + Worker.STACK_SIZE;
        const thread_stack_offset = Thread.STACK_SIZE * self.thread_pool.num_stacks;
        if (system.USES_CUSTOM_STACKS and thread_stack_offset > 0)
            end_ptr = self.thread_pool.stack_ptr + thread_stack_offset;

        // deinit the node and free it
        self.deinit();
        const memory_size = end_ptr - @ptrToInt(self);
        const memory = @ptrCast([*]align(std.mem.page_size) u8, self)[0..memory_size];
        system.unmap(memory);
    }
};

const Thread = struct {
    threadlocal var current: ?*Thread = null;

    const STACK_ALIGN = std.mem.page_size;
    const STACK_SIZE = 16 * 1024; // PTHREAD_STACK_MIN
    const MAX_STACKS = @as(comptime_int, ~@as(u16, 0));
    const DEFAULT_THREADS = 10 * 1000; // the default in rust tokio & golang

    next: ?*Thread,
    node: *Node,
    stack_ptr: ?[*]align(STACK_ALIGN) u8,
    worker: ?*Worker,
    inner: system.Thread,

    const EXIT_WORKER = @intToPtr(*Worker, 0x1);
    const MONITOR_WORKER = @intToPtr(*Worker, 0x2);

    fn wakeWith(self: *Thread, worker: *Worker) void {
        // TODO
    }

    fn entry(spawner: *Pool.Spawner) void {
        var self = spawner.instance;
        spawner.setThread(&self);
        // TODO
    }

    const Pool = struct {
        stack_ptr: usize,
        stack_top: u16,
        num_stacks: u16,
        max_active: u16,
        active_threads: u16,
        free_stack: ?*?*usize,
        free_thread: ?*Thread,

        pub const Error = error{
            InvalidThreadStack,
        };

        fn init(thread_stacks: ?[]align(Thread.STACK_ALIGN) u8, max_active: u16) Error!Pool {
            const stacks = thread_stacks orelse @as([*]align(Thread.STACK_ALIGN) u8, undefined)[0..0];
            if (stacks.len % Thread.STACK_SIZE != 0)
                return Error.InvalidThreadStack;
            if (stacks.len / Thread.STACK_SIZE > MAX_STACKS)
                return Error.InvalidThreadStack;

            const num_stacks = @truncate(u16, stacks.len / Thread.STACK_SIZE);
            return Pool{
                .stack_ptr = @ptrToInt(stacks.ptr),
                .stack_top = num_stacks,
                .num_stacks = num_stacks,
                .max_active = max_active,
                .active_threads = 0,
                .free_stack = null,
                .free_thread = null,
            };
        }

        fn deinit(self: *Pool) void {
            const mutex = &@fieldParentPtr(Node, "thread_pool", self).thread_mutex;
            const held = mutex.acquire();
            defer held.release();
            defer mutex.deinit();
            self.* = undefined;

            // send all idle threads the exit signal and wait for them to exit
            var free_list = self.free_thread;
            while (free_list) |thread| {
                thread.wakeWith(Thread.EXIT_WORKER);
                free_list = thread.next;
            }
            while (self.free_thread) |thread| {
                thread.inner.join();
                self.free_thread = thread.next;
            }
        }

        fn put(self: *Pool, thread: *Thread) void {
            const node = @fieldParentPtr(Node, "thread_pool", self);
            const held = node.thread_mutex.acquire();
            
            // exit the thread if theres too many active ones
            if (self.active_threads >= self.max_active) {
                if (thread.stack_ptr) |s| {
                    const ptr = @ptrCast(?*?*usize, &s[Thread.STACK_SIZE - @sizeOf(usize)]);
                    ptr.* = self.free_stack;
                    self.free_stack = ptr;
                }
                self.active_threads -= 1;
                held.release();
                return thread.inner.exit();
            }

            // can have more active threads so append it to the thread free list
            thread.next = self.free_thread;
            self.free_thread = thread;
            return held.release();
        }

        fn get(self: *Pool) ?*Thread {
            const node = @fieldParentPtr(Node, "thread_pool", self);
            const held = node.thread_mutex.acquire();
            
            // try and pop an idle thread from the free list
            if (self.free_thread) |free_thread| {
                const thread = free_thread;
                self.free_thread = thread.next;
                held.release();
                return thread;
            }

            // no idle thread, need to create one.
            // try and allocate a stack for the thread to create.
            var is_fresh_stack = false;
            var stack: ?[]align(Thread.STACK_ALIGN) u8 = null;
            if (system.Thread.USES_CUSTOM_STACKS and self.num_stacks > 0) {
                // check if theres a free stack in the free list
                if (self.free_stack) |free_stack| {
                    const ptr = @ptrToInt(free_stack) - (Thread.STACK_SIZE - @sizeOf(usize));
                    stack = @intToPtr([*]align(Thread.STACK_ALIGN) u8, ptr)[0..Thread.STACK_SIZE];
                    self.free_stack = free_stack.*;
                // if not, bump allocate a new stack segment
                } else if (self.stack_top != 0) {
                    self.stack_top -= 1;
                    is_fresh_stack = true;
                    const ptr = self.stack_ptr + (self.stack_top * Thread.STACK_SIZE);
                    stack = @intToPtr([*]align(Thread.STACK_ALIGN) u8, ptr)[0..Thread.STACK_SIZE];
                // thread spawning requires custom stack but no stack space available
                } else {
                    held.release();
                    return null;
                }
            }

            // spawn the thread using the given stack
            var spawner = Spawner.init(node, stack);
            defer spawner.deinit();
            spawner.instance.inner = system.Thread.spawn(stack, Thread.STACK_SIZE, &spawner, Thread.entry) catch {
                // restore back the allocated stack if the thread failed to spawn
                if (stack) |s| {
                    if (is_fresh_stack) {
                        self.stack_top += 1;
                    } else {
                        const ptr = @ptrCast(?*?*usize, &s[Thread.STACK_SIZE - @sizeOf(usize)]);
                        ptr.* = self.free_stack;
                        self.free_stack = ptr;
                    }
                }
                held.release();
                return null;
            };

            // thread created, return its pointer once it's set.
            self.active_threads += 1;
            held.release();
            return spawner.getThread();
        }

        const Spawner = struct {
            instance: Thread,
            thread: ?*Thread,
            parker: std.ThreadParker,
            const PARKED = @intToPtr(*Thread, 0x1);

            fn init(node: *Node, stack: ?[]align(Thread.STACK_ALIGN) u8) Spawner {
                return Spawner{
                    .instance = Thread{
                        .next = null,
                        .node = node,
                        .stack_ptr = if (stack) |s| s.ptr else null,
                        .worker = null,
                        .inner = undefined,
                    },
                    .thread = null,
                    .parker = std.ThreadParker.init(),
                };
            }

            fn deinit(self: *Spawner) void {
                self.parker.deinit();
            }

            fn setThread(self: *Spawner, thread: *Thread) void {
                if (@atomicRmw(?*Thread, &self.thread, .Xchg, thread, .Release) == PARKED)
                    self.parker.unpark(@ptrCast(*const u32, &self.thread));
            }

            fn getThread(self: *Spawner) *Thread {
                // try and get the thread by spinning
                var spin_count: usize = 0;
                while (spin_count < 10) : (spin_count += 1) {
                    if (spin_count > 0 and spin_count <= 3) {
                        std.SpinLock.yield(@as(usize, 1) << @truncate(u2, spin_count));
                    } else {
                        std.os.sched_yield() catch {};
                    }
                    return @atomicLoad(?*Thread, &self.thread, .Monotonic) orelse continue;
                }

                // park until the thread is set
                if (@atomicRmw(?*Thread, &self.thread, .Xchg, PARKED, .Acquire) != null)
                    self.parker.park(@ptrCast(*const u32, &self.thread), @ptrCast(*const u32, PARKED).*);
                return @atomicLoad(?*Thread, &self.thread, .Monotonic) orelse unreachable;
            }
        };
    };
};

pub const Worker = struct {
    const STACK_ALIGN = 64 * 1024;
    const STACK_SIZE = 1 * 1024 * 1024;

    // keep the head and tail on their own cache line
    runq_head: usize,
    runq_tail: usize,
    runq: [256]*Task align(sync.CACHE_LINE),

    // keep the mutex on its own cache line
    lowq_mutex: std.Mutex,
    lowq_size: usize align(sync.CACHE_LINE),
    lowq_tail: ?*Task,
    lowq_head: ?*Task,

    node: *Node,
    runq_tick: usize,
    monitor_tick: usize,
    stack_ptr: ?[*]align(STACK_ALIGN) u8,

    fn submit(self: *Worker, task: *Task) void {
        _ = @atomicRmw(usize, self.node.executor.active_tasks, .Add, 1, .Monotonic);
        // TODO: 
    }

    fn run(self: *Worker) void {

    }
};

const Task = struct {
    next: ?*Task,
    frame: usize,

    const Priority = enum(u2) {
        Low,
        Normal,
        High,
        Root,
    };

    fn init(frame: anyframe, comptime priority: Priority) Task {
        return Task{
            .next = null,
            .frame = @ptrToInt(ptr) | @enumToInt(priority),
        };
    }

    fn getPriority(self: Task) Priority {
        return @intToEnum(Priority, @truncate(@TagType(Priority), self.frame));
    }

    fn getFrame(self: Task) anyframe {
        return @intToPtr(anyframe, self.frame & ~@as(usize, ~@as(@TagType(Priority), 0)));
    }

    fn setPriority(self: *Task, priority: Priority) void {
        self.frame = @ptrToInt(self.getFrame()) | @enumToInt(priority);
    }

    fn setFrame(self: *Task, frame: anyframe) void {
        self.frame = @ptrToInt(frame) | @enumToInt(self.getPriority());
    }

    fn prepare(self: *Task, comptime func: var, args: ...) @typeOf(func).ReturnType {
        suspend self.* = Task{
            .next = null,
            .frame = @frame(),
        };
        return func(args);
    }
};