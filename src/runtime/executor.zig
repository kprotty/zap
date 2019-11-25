const std = @import("std");
const builtin = @import("builtin");

pub const Executor = struct {
    allocator: ?*std.mem.Allocator,
    workers: []Worker,
    active_tasks: usize,
    idle_workers: ?*Worker,

    runq_lock: std.Mutex,
    runq_size: usize,
    runq_head: ?*Task,
    runq_tail: ?*Task,

    thread_lock: std.Mutex,
    idle_threads: ?*Thread,
    free_threads: usize,
    monitor_thread: ?*Thread,
    monitor_tick: u64,

    pub fn init(self: *Executor) !void {
        if (builtin.single_threaded)
            return self.initSequential();
        
        const max_threads = 1024;
        const max_workers = try std.Thread.cpuCount();
        return self.initParallel(max_workers, max_threads);
    }

    pub fn initSequential(self: *Executor) !void {
        return self.initUsing(([_]Worker{ undefined })[0..], 1, null);
    }

    pub fn initParallel(self: *Executor, max_workers: usize, max_threads: usize) !void {
        const num_threads = std.math.max(1, max_threads);
        const num_workers = std.math.min(num_threads, std.math.max(1, max_workers));
        if (num_threads == 1)
            return self.initSequential();

        // TODO: Use a better allocator
        const allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.direct_allocator;
        const workers = try allocator.alloc(Worker, num_workers);
        return self.initUsing(workers, num_threads, allocator);
    }

    pub fn initUsing(self: *Executor, workers: []Worker, max_threads: usize, allocator: ?*std.mem.Allocator) !void {
        self.* = Executor{
            .allocator = allocator,
            .workers = workers,
            .active_tasks = 0,
            .idle_workers = null,
            .runq_lock = std.Mutex.init(),
            .runq_size = 0,
            .runq_head = null,
            .runq_tail = null,
            .thread_lock = std.Mutex.init(),
            .idle_threads = null,
            .free_threads = max_threads,
            .monitor_thread = null,
            .monitor_tick = 0,
        };
    }

    pub fn deinit(self: *Executor) void {
        if (self.allocator) |allocator| {
            allocator.free(self.workers);
        }
    }

    pub fn beginOneEvent(self: *Executor) void {}
    pub fn finishOneEvent(self: *Executor) void {}

    pub fn run(self: *Executor) void {

    }
};

const Thread = struct {
    threadlocal var current: ?*Thread = null;

};

const Worker = struct {

};

const Task = struct {
    next: ?*Task,
    frame: anyframe,
};