const std = @import("std");
const zap = @import("./src/zap.zig");

pub fn main() !void {
    try (try zap.Task.run(.{}, asyncMain, .{}));
}

fn asyncMain() callconv(.Async) !void {
    const allocator = std.heap.page_allocator;

    const num_workers = 100;
    const frames = try allocator.alloc(@Frame(worker), num_workers);
    defer allocator.free(frames);

    var batch = zap.Task.Batch{};
    var remaining: usize = num_workers;
    var main_task = zap.Task.init(@frame());

    suspend {
        for (frames) |*frame|
            frame.* = async worker(&batch, &remaining, &main_task);
        batch.schedule();
    }
}

fn worker(batch: *zap.Task.Batch, remaining_ptr: *usize, main_task: *zap.Task) void {
    suspend {
        var task = zap.Task.init(@frame());
        batch.push(&task);
    }

    var num_yields: usize = 100;
    while (num_yields > 0) : (num_yields -= 1) {
        zap.Task.yield();
    }

    suspend {
        const remaining = @atomicRmw(usize, remaining_ptr, .Sub, 1, .Monotonic);
        if (remaining == 1) {
            main_task.scheduleNext();
        }
    }
}