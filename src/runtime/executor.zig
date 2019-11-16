const std = @import("std");
const builtin = @import("builtin");

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

        var main_task: Task = undefined;
        _ = async Task.prepare(&main_task, entry, args);
        
        const main_node = nodes[system.getRandom().uintAtMost(usize, nodes.len)];
        const main_worker = main_node.getIdleWorker().?;
        main_worker.submit(&main_task);
        main_worker.run();
    }
};

pub const Node = struct {
    const MAX_WORKERS = @typeInfo(usize).Int.bits;
    const WorkerIndex = @Type(builtin.TypeInfo{
        .Int = builtin.TypeInfo.Int{
            .is_signed = false,
            .bits = @ctz(usize, MAX_WORKERS),
        },
    });

    executor: *Executor,
    workers: []Worker,
    idle_workers: usize,
    thread_free_list: ?*Thread,
    thread_free_count: u16,
    thread_stack_count: u16,
    thread_stack_top: u16,
    thread_stack_end: u16,

    thread_free_mutex: std.Mutex,
    thread_exit_mutex: std.Mutex,
    thread_exit_stack: [64]u8 align(16),

    pub fn init(workers: []Worker, thread_stack: ?[]u8) !Node {
        return Node{
            .executor = undefined,
            .workers = workers,
            .idle_workers = switch (std.math.min(workers.len, MAX_WORKERS)) {
                MAX_WORKERS => ~@as(usize, 0),
                else => (@as(usize, 1) << @truncate(WorkerIndex, workers.len)) - 1,
            },
        };
    }

    pub fn deinit(self: *Node) void {

    }

    pub fn alloc(numa_node: u32, max_workers: ?usize, max_threads: ?usize) !*Node {
        
    }

    pub fn free(self: *Node) void {
        self.deinit();
    }

    fn setIdleWorker(self: *Node, worker: *Worker) void {
        const offset = @ptrToInt(worker) - @ptrToInt(self.node.workers.ptr);
        const index = @truncate(WorkerIndex, offset / @sizeOf(Worker));
        _ = @atomicRmw(usize, &self.idle_workers, .Or, @as(usize, 1) << index, .Release);
    }

    fn getIdleWorker(self: *Node) ?*Worker {
        var mask = @atomicLoad(usize, &self.idle_workers, .Monotonic);
        while (mask != 0) {
            const index = @truncate(WorkerIndex, @ctz(usize, ~mask));
            const updated = mask | (@as(usize, 1) << index);
            mask = @cmpxchgWeak(usize, &self.idle_workers, mask, updated, .Acquire, .Monotonic)
                orelse return &self.workers[index];
        }
        return null;
    }

    fn getFreeThread(self: *Node) ?*Thread {
        const held = self.therad_free_mutex.acquire();
        
        if (self.thread_free_list) |free_thread| {
            if ()
        }
    }
};

const Thread = struct {
    pub threadlocal var current: ?*Thread = null;

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