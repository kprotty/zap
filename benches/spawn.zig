const std = @import("std");
const zap = @import("zap");
const allocator = std.heap.page_allocator;

const num_tasks = 100_000;
const num_spawners = 10;

pub fn main() !void {
    try (try zap.Task.run(.{}, asyncMain, .{}));
}

fn asyncMain() callconv(.Async) !void {
    const frames = try allocator.alloc(@Frame(spawner), num_spawners);
    defer allocator.free(frames);

    var task = zap.Task.init(@frame());
    var counter: usize = num_tasks * num_spawners;
    
    suspend {
        var batch = zap.Task.Batch{};
        for (frames) |*frame| {
            frame.* = async spawner(&batch, &counter, &task);
        }
        batch.schedule();
    }

    const count = @atomicLoad(usize, &counter, .Monotonic);
    if (count != 0)
        std.debug.panic("bad counter", .{});
}

fn spawner(batch: *zap.Task.Batch, counter: *usize, main_task: *zap.Task) !void {
    suspend {
        var task = zap.Task.init(@frame());
        batch.push(&task);
    }

    const frames = try allocator.alloc(@Frame(runner), num_tasks);
    defer allocator.free(frames);

    suspend {
        var runnber_batch = zap.Task.Batch{};
        for (frames) |*frame| {
            frame.* = async runner(&runnber_batch, counter, main_task);
        }
        runnber_batch.schedule();
    }
}

fn runner(batch: *zap.Task.Batch, counter: *usize, main_task: *zap.Task) void {
    suspend {
        var task = zap.Task.init(@frame());
        batch.push(&task);
    }

    suspend {
        const count = @atomicRmw(usize, counter, .Sub, 1, .Monotonic);
        if (count == 1) {
            main_task.scheduleNext();
        }
    }
}