const std = @import("std");
const zap = @import("zap");

const Task = zap.runtime.Task;
const allocator = std.heap.page_allocator;

const num_spawners = 10;
const num_tasks = 100_000;
const num_yields = 100;

pub fn main() !void {
    try (try Task.runAsync(.{}, asyncMain, .{}));
}

fn asyncMain() callconv(.Async) !void {
    const frames = try allocator.alloc(@Frame(spawner), num_spawners);
    defer allocator.free(frames);

    var task = Task.initAsync(@frame());
    var counter: usize = num_tasks * num_spawners;
    
    suspend {
        var batch = Task.Batch{};
        for (frames) |*frame| {
            frame.* = async spawner(&batch, &counter, &task);
        }
        batch.scheduleNext();
    }

    const count = @atomicLoad(usize, &counter, .Monotonic);
    if (count != 0)
        std.debug.panic("bad counter", .{});
}

fn spawner(batch: *Task.Batch, counter: *usize, main_task: *Task) !void {
    suspend {
        var task = Task.initAsync(@frame());
        batch.push(&task);
    }

    const frames = try allocator.alloc(@Frame(runner), num_tasks);
    defer allocator.free(frames);

    suspend {
        var runnber_batch = Task.Batch{};
        for (frames) |*frame| {
            frame.* = async runner(&runnber_batch, counter, main_task);
        }
        runnber_batch.schedule();
    }
}

fn runner(batch: *Task.Batch, counter: *usize, main_task: *Task) void {
    suspend {
        var task = Task.initAsync(@frame());
        batch.push(&task);
    }

    var i: usize = num_yields;
    while (i != 0) : (i -= 1) {
        Task.yieldAsync();
    }

    suspend {
        const count = @atomicRmw(usize, counter, .Sub, 1, .Monotonic);
        if (count == 1) {
            main_task.scheduleNext();
        }
    }
}