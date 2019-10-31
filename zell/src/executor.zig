const std = @import("std");
const builtin = @import("builtin");
const zuma = @import("../../zap.zig").zuma;
const zync = @import("../../zap.zig").zync;
const zell = @import("../../zap.zig").zell;

pub const Executor = struct {
    /// Run the given function using the arguments on an executor.
    /// The implementation is free to choose which methods it deems most efficient to do so.
    pub fn run(comptime func: var, args: ...) !@typeOf(func).ReturnType {
        var self = @This(){};
        if (builtin.single_threaded)
            return self.runSequential(func, args);
        return self.runParallel(func, args);
    }

    /// Run the given function using the arguments on the executor.
    /// Ensures that the code being executed runs on a single thread
    /// *NOT* that the system doesnt spawn any other threads.
    pub fn runSequential(self: *@This(), comptime func: var, args: ...) !@typeOf(func).ReturnType {
        var main_node = Node{};
        try main_node.init(self, 0, [_]Worker{undefined});
        defer main_node.deinit();
        return self.runWithNodes([_]*Node{&main_node}, func, args);
    }

    /// Run the given function using the arguments on the executor.
    /// Unlike `runSequential` this optimizes for multicore systems.
    pub fn runParallel(self: *@This(), comptime func: var, args: ...) !@typeOf(func).ReturnType {
        var node_array = [_]*Node{@intToPtr(*Node, 1)} ** Node.MAX;
        const num_nodes = zuma.CpuAffinity.getNodeCount();
        const nodes = node_array[0..num_nodes];
        for (nodes) |*node, numa_node|
            node.* = try Node.alloc(self, numa_node);
        defer for (nodes) |node|
            if (@ptrToInt(node) != 1)
                node.free();
        return self.runWithNodes(nodes, func, args);
    }

    fn runWithNodes(self: *@This(), nodes: []*Node, comptime func: var, args: ...) !@typeOf(func).ReturnType {
        return error.Todo;
    }
};

pub const Node = struct {
    /// Maximum number of nodes running concurrently on the system.
    pub const MAX = 64;

    pub fn init(self: *@This(), executor: *Executor, numa_node: u32, workers: []Worker) !void {}

    pub fn deinit(self: *@This()) void {}

    pub fn alloc(executor: *Executor, numa_node: u32) !*@This() {}

    pub fn free(self: *@This()) void {
        self.deinit();
    }
};

pub const Worker = struct {
    /// Maximum number of workers running concurrently in one Node
    pub const MAX = @typeInfo(usize).Int.bits;
};

pub const Thread = struct {
    /// Maximum number of Operating System Threads running concurrently in one Node
    pub const MAX = 10 * 1000;
};

pub const Task = struct {
    next: ?*@This() = null,
    frame: anyframe = undefined,

    pub fn withResult(comptime func: var, result: *?@typeOf(func).ReturnType, args: ...) void {
        result.* = null;
        const value = func(args);
        result.* = value;
    }

    pub const List = struct {
        size: usize = 0,
        head: ?*Task = null,
        tail: ?*Task = null,

        pub fn push(self: *@This(), task: *Task) void {
            self.size += 1;
            task.next = null;
            if (self.tail) |tail|
                tail.next = task;
            self.tail = task;
            if (self.tail) |tail|
                self.head = tail;
        }

        pub fn iter(self: @This()) Iterator {
            return Iterator{ .current = self.head };
        }

        pub const Iterator = struct {
            current: ?*Task = null,

            pub fn next(self: *@This()) ?*Task {
                const task = self.current;
                if (self.current) |current_task|
                    self.current = current_task.next;
                return task;
            }
        };
    };
};
