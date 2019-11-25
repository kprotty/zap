const std = @import("std");
const builtin = @import("builtin");

pub const Executor = struct {
    
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

    pub fn run(comptime entryFn: var, args: ...) !@typeOf(entryFn).ReturnType {
        if (builtin.single_threaded)
            return runUsing(1, 1, entryFn, args);

        const num_threads = 1024; // arbitrary
        const num_cpus = try std.Thread.cpuCount(); 
        return runUsing(num_cpus, num_threads, entryFn, args);
    }

    pub fn runUsing(max_workers: usize, max_threads: usize, comptime entryFn: var, args: ...) !@typeOf(entryFn).ReturnType {
        const num_threads = std.math.max(1, max_threads);
        const num_workers = std.math.min(num_threads, std.math.max(1, num_workers));
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