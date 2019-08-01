
pub const Scheduler = struct {
    pub var current: Scheduler = undefined;

    

    pub const Task = struct {
        next: ?*Task,
        handle: promise,
    };

    pub const Config = struct {
        num_threads: u8,
        allocator: *std.mem.Allocator,
    }

    pub fn run(config: Config, comptime function: var, args: ...) !void {

    }

    pub fn spawn(self: *Scheduler, comptime function: var, args: ...) *Task {

    }

    pub fn submit(self: *Scheduler, task: *Task) void {

    }

    pub async fn yield(self: *Scheduler) void {

    }
};