const std = @import("std");
const executor = @import("./zap/executor.zig");

pub fn run(frame: anyframe) !void {
    var task = executor.Task.init(frame);
    executor.Scheduler.run(.{}, task.toBatch());
}

pub fn reschedule() void {
    suspend {
        var task = executor.Task.init(@frame());
        const worker = executor.Worker.getCurrent().?;
        worker.schedule(task.toBatch(), .{ .use_lifo = true });
    }
}

pub fn shutdown() void {
    const worker = executor.Worker.getCurrent().?;
    const scheduler = worker.getScheduler();
    scheduler.shutdown();
}
