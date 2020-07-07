const std = @import("std");
const zap = @import("zap");

const num_spawners = 10;
const num_tasks_per_spawner = 500 * 1000;
const num_tasks = num_tasks_per_spawner * num_spawners;

pub fn main() !void {
    try (try zap.Scheduler.run(.{}, asyncMain, .{}));
}

fn asyncMain() !void {
    const inc_frames = try std.heap.page_allocator.alloc(@Frame(inc), num_tasks);
    defer std.heap.page_allocator.free(inc_frames);

    const spawner_frames = try std.heap.page_allocator.alloc(@Frame(spawner), num_spawners);
    defer std.heap.page_allocator.free(spawner_frames);

    var spawned: usize = 0;
    var task = zap.Task.init(@frame());
    
    suspend {
        for (spawner_frames) |*frame, i| {
            var frames = inc_frames[(i * num_tasks_per_spawner)..];
            const frames_end = std.math.min(num_tasks_per_spawner, frames.len);
            frame.* = async spawner(&spawned, &task, frames[0..frames_end]);
        }
    }

    const task_spawned = @atomicLoad(usize, &spawned, .SeqCst);
    if (task_spawned != num_tasks) {
        std.debug.panic("Bad spawned count", .{});
    }
}

fn spawner(spawned: *usize, task: *zap.Task, frames: []@Frame(inc)) void {
    zap.Task.yieldNext();

    var batch = zap.Task.Batch.init();
    for (frames) |*frame| {
        frame.* = async inc(spawned, task, &batch);
    }

    batch.scheduleNext();
}

fn inc(spawned: *usize, task: *zap.Task, batch: *zap.Task.Batch) void {
    var self = zap.Task.init(@frame());
    suspend {
        batch.push(&self);
    }

    const spawned_count = @atomicRmw(usize, spawned, .Add, 1, .SeqCst);
    if (spawned_count == num_tasks - 1) {
        task.scheduleNext();
    }
}