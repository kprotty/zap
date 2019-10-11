const std = @import("std");
const zio = @import("../../zap.zig").zio;
const zync = @import("../../zap.zig").zync;
const zuma = @import("../../zap.zig").zuma;

pub const Scheduler = struct {
    nodes: []*Node,
    is_sequential: bool,
    active_tasks: zync.Atomic(usize),

    pub inline fn yield() void {
        return Task.yield();
    }

    pub fn call(comptime func: var, args: ...) @typeOf(func).ReturnType {
        yield();
        return func(args);
    }

    pub fn runSequential(self: *@This(), comptime func: var, args: ...) !@typeOf(func).ReturnType {

    }

    pub fn runParallel(self: *@This(), comptime func: var, args: ...) !@typeOf(func).ReturnType {
        
    }

    pub fn runWith(self: *@This(), nodes: []*Node, comptime func: var, args: ...) !@typeOf(func).ReturnType {
        std.debug.assert(nodes.len > 0);
        for (nodes) |node|
            std.debug.assert(node.workers.len > 0);

        self.nodes = nodes;
        self.active_tasks.set(0);
        self.is_sequential = nodes.len == 1 and nodes[0].workers.len == 1;

        const main_node = self.nodes[zuma.Thread.getRandom().uintAtMost(usize, nodes.len - 1)];
        const main_worker = main_node.workers[0];
        Worker.current = main_worker;
        
        var result: @typeOf(func).ReturnType = undefined;
        _ = main(&result, func, args);
    }

    fn main(result_ptr: *@typeOf(func).ReturnType, comptime func: var, args: ...) void {
        yield();
        result_ptr.* = func(args);
    }
};

pub const Node = struct {
    scheduler: *Scheduler,
    workers: []*Worker,
    poller: zio.Event.Poller,
    run_queue: Worker.GlobalQueue,

    pub fn init(self: *@This(), scheduler: *Scheduler, numa_node: usize, workers: []*Worker) !void {

    }

    pub fn deinit(self: *@This()) void {

    }

    pub fn alloc(scheduler: *Scheduler, numa_node: usize) !*@This() {

    }

    pub fn free(self: *@This()) void {

    }
};

pub const Worker = struct {
    pub threadlocal var current: ?*Worker = null;

    node: *Node,
    next_task: ?*Task,
    run_queue: LocalQueue,

    pub const GlobalQueue = struct {

    };

    pub const LocalQueue = struct {
        head: zync.Atomic(usize),
        tail: zync.Atomic(usize),
        tasks: zync.CachePadded([256]*Task),
        
        pub fn init(self: *@This()) void {

        } 

        pub fn push(self: *@This(), list: ?*Task, list_size: usize) void {

        }

        pub fn pop(self: *@This()) ?*Task {

        }

        pub fn steal(self: *@This(), other: *@This()) usize {

        }
    };
};

pub const Task = struct {
    next: ?*Task,
    frame: anyframe,

    pub inline fn new() @This() {
        return @This() {
            .next = null,
            .frame = @frame(),
        };
    }

    pub inline fn yield() {
        suspend {
            const worker = Worker.current orelse resume @frame();
            var self = new();
            worker.next_task = &self;
        }
    }
};