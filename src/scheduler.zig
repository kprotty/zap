const std = @import("std");
const builtin = @import("builtin");

const atomic = @import("atomic.zig");
const heap = @import("heap.zig").Heap;

pub const Config = struct {
    max_workers: usize,

    pub fn default() Config {
        return Config {
            .max_workers = std.Thread.cpuCount() catch 1,
        };
    }
};  

pub const System = struct {
    heap: Heap,

    pub fn run(self: *System, config: Config, comptime function: var, args: ...) !void {
        self.heap.init();
        defer self.heap.deinit();

        Worker.idle.init();
        Thread.idle.init();
        Task.global.init();

        Worker.all = try self.heap.allocator.alloc(std.math.max(1, config.max_workers));
        defer self.heap.allocator.free(Worker.all);
        for (Worker.all) |*worker| worker.init();
        defer { for (Worker.all) |*w| w.deinit(); }

        self.monitor();
        // wait for stop event
    }
};

pub const Worker = struct {
    pub var all: []Worker = undefined;
    pub var idle: atomic.Queue(Worker, "next") = undefined;

    status: Status,
    next: ?*Worker,
    heap: Heap,
    thread: *Thread,


    pub fn init(self: *Worker) void {
        self.heap.init();
        self.status = .Idle;
        idle.push(self);
    }

    pub fn deinit(self: *Worker) void {
        self.heap.deinit();
    }

    pub fn spawn(comptime function: var, args: ...) !void {
        const TaskWrapper = struct {
            async fn func(task_ref: *Task, func_args: ...) void {
                suspend {
                    task_ref.handle = @handle();
                    task_ref.status = .Runnable;
                }
                _ = await (async function(func_args) catch unreachable);
                task_ref.status = .Completed;
            }
        };

        const task = try self.heap.allocator.init(Task);
        _ = try async<allocator> TaskWrapper.func(task, args);
    }

    pub const Status = enum {
        Idle,
        Running,
        Syscall,
    };
};

pub const Thread = struct {
    pub const max = 10 * 1000;
    pub var num_spinning = usize(0);

    pub var idle: atomic.Queue(Thread, "next") = undefined;

    next: ?*Thread,
    worker: *Worker,
    handle: ?*std.Thread,

    pub fn run(self: *Thread) void {

    }
};

pub const Task = struct {
    pub threadlocal var current: *Task = undefined;

    pub var active: usize = 0;
    pub var global = atomic.Queue(Task, "next").new();

    next: ?*Task,
    status: Status,
    handle: promise,
    thread: *Thread,

    pub const Status = enum {
        Runnable,
        Running,
        Completed,
    };

    pub fn spawn(task: *Task, allocator: *std.mem.Allocator, comptime function: var, args: ...) !void {
        
    }
};




