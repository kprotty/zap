const std = @import("std");
const builtin = @import("builtin");

const sync = @import("./sync.zig");
const system = switch (builtin.os) {
    .windows => @import("./system/windows.zig"),
    .linux => @import("./system/linux.zig"),
    else => @import("./system/posix.zig"),
};

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

        var main_task: Task = undefined;
        _ = async Task.prepare(&main_task, entry, args);
        
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

    pub fn init(workers: []Worker, thread_stack: []u8) !Node {
        return Node{
            .executor = undefined,
            .workers = workers,
            .idle_workers = sync.BitSet.init(workers.len),
            .thread_pool = Thread.Pool.init(thread_stack),
        };
    }

    pub fn deinit(self: *Node) void {
        self.thread_pool.deinit();
    }

    pub fn alloc(numa_node: u32, max_workers: ?usize, max_threads: ?usize) !*Node {
        
    }

    pub fn free(self: *Node) void {
        self.deinit();
    }
};

const Thread = struct {
    threadlocal var current: ?*Thread = null;

    const Pool = struct {

    };
};

const Worker = struct {
    const STACK_ALIGN = 64 * 1024;
    const STACK_SIZE = 1 * 1024 * 1024;

    node: *Node,
    stack_offset: u32,

    fn getStack(self: Worker) []align(STACK_ALIGN) u8 {
        const ptr = @ptrToInt(self.node) + self.stack_offset;
        return @intToPtr([*]align(STACK_ALIGN) u8, ptr)[0..STACK_SIZE];
    }

    fn submit(self: *Worker, task: *Task) void {
        _ = @atomicRmw(usize, self.node.executor.active_tasks, .Add, 1, .Monotonic);
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

    fn getPriority(self: *const Task) Priority {
        return 
    }

    fn prepare(self: *Task, comptime func: var, args: ...) @typeOf(func).ReturnType {
        suspend self.* = Task{
            .next = null,
            .frame = @frame(),
        };
        return func(args);
    }
};