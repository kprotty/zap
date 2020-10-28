const std = @import("std");
const zap = @import("zap");

const Task = zap.runtime.Task;
const Lock = zap.runtime.sync.Lock;
const allocator = std.heap.page_allocator;

const num_iters = 100;
const num_tasks = 500;

pub fn main() !void {
    try (try Task.runAsync(.{}, asyncMain, .{}));
}

fn asyncMain() !void {
    const frames = try allocator.alloc(@Frame(runner), num_tasks);
    defer allocator.free(frames);

    var lock = Lock{};
    var counter: u64 = 0;

    var batch = Task.Batch{};
    for (frames) |*frame|
        frame.* = async runner(&batch, &lock, &counter);

    batch.schedule();
    for (frames) |*frame|
        await frame;

    lock.acquireAsync();
    defer lock.release();

    if (counter != num_tasks * num_iters)
        unreachable; // invalid counter result
}

fn runner(batch: *Task.Batch, lock: *Lock, counter: *u64) void {
    suspend {
        var task = Task.initAsync(@frame());
        batch.push(&task);
    }

    var i: usize = num_iters;
    while (i != 0) : (i -= 1) {

        lock.acquireAsync();
        defer lock.release();

        counter.* += 1;
    }
}