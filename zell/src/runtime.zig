const std = @import("std");
const builtin = @import("builtin");
const zuma = @import("../../zap.zig").zuma;
const zync = @import("../../zap.zig").zync;

pub fn run(comptime func: var, args: ...) !@typeOf(func).ReturnType {
    var system: System = undefined;

    // if single_threaded, dont heap allocate 
    if (builtin.single_threaded) {
        var main_node: Node = undefined;
        var main_worker: Worker = undefined;
        try main_node.init(([_]*Worker { &main_worker })[0..]);
        return system.run(([_]*Node { &main_node })[0..]);
    }

    // allocate the node structures & their workers on their defined NUMA nodes
    var node_array: [64]*Node = undefined;
    const nodes = node_array[0..zuma.CpuAffinity.getNodeCount()];
    for (nodes) |*node, node_index|
        node.* = try Node.alloc(node_index);
    defer {
        for (nodes) |node|
            node.free();
    }
    return system.run(nodes);
}

const System = struct {
    nodes: []*Node,
    active_tasks: zync.Atomic(usize),

    pub fn run(self: *@This(), nodes: []*Node, comptime func: var, args: ...) !@typeOf(func).ReturnType {
        self.active_tasks.set(0);
    }
};

pub const Node = struct {
    system: *System,
    numa_node: usize,
    workers: []*Worker,
    
    pub fn alloc(numa_node: usize) !*@This() {

    }
};

pub const Worker = struct {
    pub threadlocal current: ?*@This() = null;

    node: *Node,

    pub fn isSequential(self: *const @This()) bool {
        return builtin.single_threaded or self.node.workers.len == 1;
    }
};

pub const Task = struct {
    next: ?*@This(),
    frame: anyframe,
};