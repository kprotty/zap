const std = @import("std");
const zap = @import("zap");

const num_tasks = 100_000;
const num_yields = 200;

pub fn main() !void {
    try (try zap.Task.run(.{}, asyncMain, .{}));
}

fn asyncMain() callconv(.Async) !void {
    const allocator = std.heap.page_allocator;

    const frames = try allocator.alloc(@Frame(worker), num_tasks);
    defer allocator.free(frames);

    var batch = zap.Task.Batch{};
    var remaining: usize = frames.len;
    var main_task = zap.Task.init(@frame());

    suspend {
        for (frames) |*frame|
            frame.* = async worker(&batch, &remaining, &main_task);
        batch.schedule();
    }

    const remains = @atomicLoad(usize, &remaining, .Monotonic);
    std.debug.assert(remains == 0);
}

fn worker(batch: *zap.Task.Batch, remaining_ptr: *usize, main_task: *zap.Task) void {
    suspend {
        var task = zap.Task.init(@frame());
        batch.push(&task);
    }

    var i: usize = num_yields;
    while (i > 0) : (i -= 1) {
        zap.Task.yield();
    }

    suspend {
        const remaining = @atomicRmw(usize, remaining_ptr, .Sub, 1, .Monotonic);
        if (remaining == 1) {
            main_task.scheduleNext();
        }
    }
}