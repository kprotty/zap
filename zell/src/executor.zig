const std = @import("std");
const builtin = @import("builtin");
const zuma = @import("../../zap.zig").zuma;
const zync = @import("../../zap.zig").zync;
const zell = @import("../../zap.zig").zell;

/// Representation of a general purpose task scheduler.
/// The design borrows heavily, and pays respects to:
/// - Golangs current scheduler implementation (https://github.com/golang/go/blob/master/src/runtime/proc.go)
/// - Rust Tokio's contributions to said scheduler (https://tokio.rs/blog/2019-10-scheduler/)
/// - Dmitry Vyukov's NUMA-aware scheduler proposal for Golang (https://docs.google.com/document/d/1d3iI2QWURgDIsSR6G2275vMeQ_X7w-qxM2Vp7iGwwuM/pub)
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
        var main_node = Node{
            .executor = self,
            .workers = [_]Worker{undefined},
            .allocator = std.heap.direct_allocator, // TODO: better allocator
            .affinity = zuma.CpuAffinity{
                .group = 0,
                .mask = 0,
            },
        };

        try main_node.init(self, Thread.MAX);
        defer main_node.deinit();
        return self.runWithNodes([_]*Node{&main_node}, func, args);
    }

    /// Run the given function using the arguments on the executor.
    /// Unlike `runSequential` this optimizes for multicore systems.
    pub fn runParallel(self: *@This(), comptime func: var, args: ...) !@typeOf(func).ReturnType {
        // Store the array of node pointers on the stack.
        // This is mostly to save an unnecessary heap allocation.
        const num_nodes = zuma.CpuAffinity.getNodeCount();
        var node_array = [_]?*Node{null} ** Node.MAX;
        const nodes = node_array[0..num_nodes];

        // Setup the defer to free the nodes first.
        // This is to ensure previously allocated nodes are cleaned up in case of error in the alloc loop.
        defer for (nodes) |node_ref|
            if (node_ref) |node|
                node.free();
        for (nodes) |*node_ref, node_index|
            node_ref.* = try Node.alloc(self, node_index);
        const real_nodes = @ptrCast([*]*Node, nodes.ptr)[0..nodes.len];
        return self.runWithNodes(real_nodes, func, args);
    }

    pub fn runUsing(self: *@This(), nodes: []*Node, comptime func: var, args: ...) !@typeOf(func).ReturnType {
        return error.Todo;
    }
};

pub const Node = struct {
    /// Maximum number of nodes running concurrently on the system.
    pub const MAX = 64;

    executor: *Executor,
    affinity: zuma.CpuAffinity,
    allocator: *std.mem.Allocator,
    reactor: zell.Reactor = undefined,

    workers: []Worker,
    thread_pool: Thread.Pool = undefined,

    pub fn init(self: *@This(), max_threads: usize) !void {
        try self.reactor.init(self.allocator);
        try self.thread_pool.init(self.allocator);
    }

    pub fn deinit(self: *@This()) void {
        self.reactor.deinit();
        self.thread_pool.deinit();
    }

    pub fn alloc(executor: *Executor, numa_node: u32) !*@This() {
        return error.Todo;
    }

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

    pub threadlocal var current: ?*@This() = null;

    pub const Pool = struct {
        pub fn init(self: *@This(), allocator: *std.mem.Allocator) !void {
            return error.Todo;
        }

        pub fn deinit(self: *@This()) void {}
    };
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
