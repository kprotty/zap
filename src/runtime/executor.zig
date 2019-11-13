const std = @import("std");
const builtin = @import("builtin");

pub const Executor = struct {
    threadlocal var node_array: [64]?*Node = undefined;

    nodes: []*Node,
    next_node: u32,
    active_workers: u32,
    active_tasks: usize,

    pub fn init() !Executor {
        if (builtin.single_threaded) {
            return initSequential();
        } else {
            return initParallel();
        }
    }

    pub fn initSequential() !Executor {
        var workers = [_]Worker{undefined};
        var node = Node.init(workers[0..], null);
        var nodes = [_]*Node{ &node };
        return initUsing(nodes[0..]);
    }

    pub fn initParallel() !Executor {
        if (builtin.single_threaded)
            @compileError("--single-threaded doesn't support parallel execution");
            
        const node_count = std.math.min(system.getNodeCount(), node_array.len);
        const nodes = @ptrCast([*]*Node, &node_array[0])[0..node_count];
        const node_slice = node_array[0..node_count];
        
        for (node_slice) |*ptr| {
            ptr.* = null;
        }
        errdefer for (node_slice) |*ptr| {
            if (ptr.*) |node| {
                node.free();
            }
        }
        for (node_slice) |*ptr, index| {
            ptr.* = try Node.alloc(index, null, null);
        }

        return initUsing(nodes);
    }

    pub fn initSMP(max_workers: usize, max_threads: usize) !Executor {
        const node = try Node.alloc(0, max_workers, max_threads);
        errdefer node.free();
        var nodes = [_]*Node{ node };
        return initUsing(nodes[0..]);
    }

    pub fn initUsing(nodes: []*Node) !Executor {
        
    }

    pub fn deinit(self: *Executor) void {

    }

    pub fn run(self: *Executor) void {
        for (self.nodes) |node|
            node.executor = self;
    }
};

pub const Node = extern struct {
    executor: *Executor,

    pub fn init(workers: []Worker, thread_stack: ?[]u8) !Node {

    }

    pub fn deinit(self: *Node) void {

    }

    pub fn alloc(numa_node: u32, max_workers: ?usize, max_threads: ?usize) !*Node {
        
    }

    pub fn free(self: *Node) void {

    }
};

const Thread = struct {
    pub threadlocal var current: ?*Thread = null;

};

const Worker = struct {
    const STACK_ALIGN = 64 * 1024;
    const STACK_SIZE = 1 * 1024 * 1024;

};

const Task = struct {
    next: ?*Task,
    frame: anyframe,
};