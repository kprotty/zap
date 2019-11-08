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
        var node_array: [_]?*Node{null} ** BitSet.Max;
        const array = node_array[0..system.getNumaNodeCount()];
        defer for (array) |ptr| {
            if (ptr) |node|
                node.free();
        }

        // Allocate each node on its corresponding numa node for locality
        for (array) |*node, index|
            node.* = try Node.alloc(self, index, 1024 + 1);
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
        const main_worker = main_node.getIdleWorker().?;
        var main_thread = Thread{
            .node = main_node,
            .link = null,
            .worker = main_worker,
        };

        Worker.current = main_worker;
        _ = async func(args);
        var main_stack: [Worker.STACK_SIZE]u8 align(Worker.STACK_ALIGN) = undefined;
        main_worker.stack = main_stack[0..];
        main_thread.run();

        self.active_workers.wait();
        for (nodes) |node| {
            while (node.thread_pool.pop()) |thread| {
                thread.wakeup(null);
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

    fn getIdleWorker(self: *Node) ?*Worker {
        return null; // TODO
    }
};

const Thread = struct {
    node: *Node,
    link: ?*Thread,
    worker: ?*Worker,
    parker: std.ThreadParker,

    pub fn wake(self: *@This(), worker: ?*Worker) void {
        if (@atomicRmw(?*Worker, &self.worker, .Xchg, worker, .Release) == null)
            self.parker.unpark(@ptrCast(*const u32, &self.worker));
    }

    const Monitor = struct {

    };

    const Pool = struct {

    };
};

pub const Worker = struct {
    pub threadlocal var current: ?*Worker= null;

    const STACK_ALIGN = if (builtin.os == .windows) 0 else std.mem.page_size;
    const STACK_SIZE = switch (builtin.os) {
        .windows => 0, // windows doesnt allow custom thread stacks
        else => switch (@typeInfo(usize).Int.bits) {
            64 => 8 * 1024 * 1024,
            32 => 2 * 1024 * 1024,
            else => @compileError("Architecture not supported"),
        },
    };

    node: *Node,
    thread: ?*Thread,
    run_queue: LocalQueue,
    blocking_task: ?*Task,
    stack: []align(STACK_ALIGN) u8,

    pub fn init(node: *Node, stack: []align(STACK_ALIGN) u8) Worker {
        return Worker{
            .node = node,
            .thread = null,
            .run_queue = LocalQueue{},
            .blocking_task = null,
            .stack = stack,
        };
    }

    pub fn submit(self: *Worker, task: *Task) void {

    }

    pub fn blocking(self: *Worker, comptime func: var, args: ...) @typeOf(func).ReturnType {
        if (builtin.single_threaded or self.node.workers.len == 1)
            return func(args);
        // TODO
    }

    fn run(self: *Worker) void {
        
    }

    const GlobalQueue = struct {
        mutex: std.Mutex = std.Mutex.init(),
        tasks: Task.List = Task.List{},
    };

    const LocalQueue = struct {
        head: u32 = 0,
        tail: u32 = 0,
        tasks: [256]*Task = undefined,

        fn p
    };
};

pub const Task = struct {
    next: ?*@This() = null,
    frame: anyframe = undefined,

    pub const Priority = enum(u2) {
        /// Schedule to end of the local queue on the current node
        Low,
        /// Schedule to the front of the local queue on the current node
        High,
        /// Distribute to other workers or nodes
        Root,
    };

    pub fn init(frame: anyframe, comptime priority: Priority) @This() {
        return @This(){
            .next = null,
            .frame = @intToPtr(anyframe, @ptrToInt(frame) | @enumToInt(priority));
        };
    }

    pub fn getFrame(self: @This()) anyframe {
        return @intToPtr(anyframe, @ptrToInt(self.frame) & ~usize(~@TagType(Priority)(0)));
    }

    pub fn getPriority(self: @This()) Priority {
        return @intToEnum(Priority, @truncate(@TagType(Priority), @ptrToInt(self.frame)));
    }

    pub const List = struct {
        size: usize = 0,
        head: ?*Task = null,
        tail: ?*Task = null,
        
        pub fn push(self: *@This(), list: @This()) void {
            if (self.tail) |tail|
                tail.next = list.head;
            self.tail = list.tail;
            if (self.head == null)
                self.head = list.head;
            self.size += list.size;
        }

        pub fn pop(self: *@This()) ?*Task {
            const head = self.head orelse return null;
            self.head = head.next;
            if (self.head == null)
                self.tail = null;
            return head;
        }
    };
};
