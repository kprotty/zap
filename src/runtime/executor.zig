const std = @import("std");
const builtin = @import("builtin");
const sync = @import("./sync.zig");

pub const Executor = struct {
    pending_tasks: usize,
    nodes: []*Node,
    idle_nodes: sync.BitSet(usize),

    pub fn run(comptime func: var, args: ...) !void {
        var self: @This() = undefined;
        if (builtin.single_threaded)
            return self.runSequential(func, args);
        return self.runParallel(func, args);
    }

    pub fn runSequential(self: *@This(), comptime func: var, args: ...) !void {
        // setup the worker on the stack
        var main_worker: Worker = undefined;
        var workers = [_]*Worker{ &main_worker };

        // setup the node on the stack
        var main_node = try Node.init(self, workers[0..]);
        defer main_node.deinit();
        var nodes = [_]*Node{ &main_node };
        return self.runUsing(nodes, func, args);
    }

    pub fn runParallel(self: *@This(), comptime func: var, args: ...) !void {
        // store the array of node pointers on the stack.
        // since its on the stack, limit the maximum amount of numa nodes.
        // also perform the `defer` first to make sure all nodes are freed in case of error
        var node_array: [_]?*Node{null} ** @typeInfo(usize).Int.bits;
        const array = node_array[0..system.Thread.getNumaNodeCount()];
        defer for (array) |ptr| {
            if (ptr) |node|
                node.free();
        }

        // Allocate each node on its corresponding numa node for locality
        for (array) |*node, index|
            node.* = try Node.alloc(self, index);
        const nodes = @ptrCast([*]Node, array.ptr)[0..array.len];
        return self.runUsing(nodes, func, args);
    }

    pub fn runUsing(self: *@This(), nodes: []*Node, comptime func: var, args: ...) !void {
        self.nodes = nodes;
        self.pending_tasks = 0;
        self.idle_nodes = sync.BitSet(usize).init(node.len);
        _ = async func(args);
        
        // start with a random numa node in order to not over-subscribe on a single
        // one if theres multiple numa applications running on the system.
        const start_node = &nodes[system.getRandom().uintAtMost(usize, nodes.len)];
        start_node.run();
    }
};

pub const Node = struct {
    executor: *Executor,
    workers: []*Worker,
    idle_workers: usize,

    pub fn init(executor: *Executor, workers: []*Worker) !@This() {

    }

    pub fn deinit(self: *@This()) void {

    }

    pub fn alloc(executor: *Executor, numa_node: u16) !*@This() {

    }

    pub fn free(self: *@This()) void {

    }
};

pub const Worker = struct {
    node: *Node,
    run_queue: LocalQueue,

    const GlobalQueue = struct {
        mutex: sync.Mutex = sync.Mutex.init(),
        tasks: Task.List = Task.List{},
    };

    const LocalQueue = struct {
        head: u32 = 0,
        tail: u32 = 0,
        tasks: [256]*Task = undefined,

        fn p
    };
};

const Thread = struct {
    threadlocal var current = @This(){};

    worker: ?*Worker,
};

const Task = struct {
    next: ?*@This() = null,
    frame: anyframe = undefined,

    const List = struct {
        size: usize = 0,
        head: ?*Task = null,
        tail: ?*Task = null,
        
        fn push(self: *@This(), list: @This()) void {
            if (self.tail) |tail|
                tail.next = list.head;
            self.tail = list.tail;
            if (self.head == null)
                self.head = list.head;
            self.size += list.size;
        }
    };
};