const Scheduler = @import("src/scheduler.zig").Scheduler;

pub const runtime = struct {
    pub const Task = Scheduler.Task;
    pub const Config = Scheduler.Config;

    pub inline fn run(config: Config, comptime main: var, args: ...) !void {
        return Scheduler.run(config, main, args);
    }

    pub inline fn spawn(comptime function: var, args: ...) *Task {
        return Scheduler.current.spawn(function, args);
    }

    pub async fn yield() void {
        await (async Scheduler.current.yield() catch unreachable);
    }
};