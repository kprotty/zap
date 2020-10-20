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
        for (frames) |*frame| {
            frame.* = async spawner(&counter, &task);
        }
    }

    const count = @atomicLoad(usize, &counter, .Monotonic);
    if (count != 0)
        std.debug.panic("bad counter", .{});
}

fn spawner(counter: *usize, main_task: *zap.Task) !void {
    zap.Task.runConcurrently();

    const frames = try allocator.alloc(@Frame(worker), num_tasks);
    defer allocator.free(frames);

    suspend {
        for (frames) |*frame| {
            frame.* = async worker(counter, main_task);
        }
    }
}

fn worker(counter: *usize, main_task: *zap.Task) void {
    zap.Task.runConcurrently();

    suspend {
        const count = @atomicRmw(usize, counter, .Sub, 1, .Monotonic);
        if (count == 1) {
            main_task.scheduleNext();
        }
    }
}