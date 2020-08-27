const std = @import("std");
const zap = @import("zap");

const num_tasks = 100;

pub fn main() !void {
    try (try (zap.Task.runAsync(asyncMain, .{})));
}

fn asyncMain() !void {
    const allocator = zap.Task.getAllocator();
    const frames = try allocator.alloc(@Frame(asyncWorker), num_tasks);
    defer allocator.free(frames);

    var counter: usize = 0;
    var event = zap.Task.init(@frame());
    
    suspend {
        var batch = zap.Task.Batch{};
        for (frames) |*frame|
            frame.* = async asyncWorker(&batch, &event, &counter);
        batch.schedule();
    }

    const completed = @atomicLoad(usize, &counter, .Monotonic);
    if (completed != num_tasks)
        std.debug.panic("Only {}/{} tasks completed\n", .{completed, num_tasks});
}

fn asyncWorker(batch: *zap.Task.Batch, event: *zap.Task, counter: *usize) void {
    suspend {
        var task = zap.Task.init(@frame());
        batch.push(&task);
    }

    std.debug.warn("Running on tid {}\n", .{std.Thread.getCurrentId()});

    suspend {
        const completed = @atomicRmw(usize, counter, .Add, 1, .Monotonic);
        if (completed + 1 == num_tasks)
            event.scheduleNext();
    }
}