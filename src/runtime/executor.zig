const std = @import("std");
const builtin = @import("builtin");

pub const Executor = struct {
    nodes: []*Node,
    next_node: u32,
    active_workers: u32,
    active_tasks: usize,

    pub fn runSequential(comptime entry: var, args: ...) !void {
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
        
        var node_array = [_]?*Node{null} ** 64;
        const node_count = std.math.min(system.getNodeCount(), node_array.len);
        const nodes = @ptrCast([*]*Node, &node_array[0])[0..node_count];

        defer for (node_array[0..node_count]) |*node_ptr| {
            if (node_ptr.*) |node|
                node.free();
        }
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