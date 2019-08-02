const builtin = @import("builtin");
const queue = @import("sync/queue.zig").SharedQueue;

// https://golang.org/s/go11sched
pub const Scheduler = struct {
    pub var current: Scheduler = undefined;

    workers: []Worker,  

    pub const Task = extern struct {
        next: ?*Task,
        handle: promise,
    };

    pub const Config = struct {
        max_workers: usize,
        allocator: *std.mem.Allocator,

        pub fn default() Config {
            
        }
    };

    pub fn run(config: ?Config, comptime function: var, args: ...) !void {

    }

    pub fn spawn(self: *Scheduler, comptime function: var, args: ...) *Task {

    }

    pub fn submit(self: *Scheduler, task: *Task) void {

    }

    pub async fn yield(self: *Scheduler) void {

    }
};