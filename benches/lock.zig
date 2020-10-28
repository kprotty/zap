const std = @import("std");
const zap = @import("zap");

const Task = zap.runtime.Task;
const Lock = zap.runtime.sync.Lock;
const allocator = std.heap.page_allocator;

const num_iters = 100;
const num_tasks = 500;

pub fn main() !void {
    try (try Task.runAsync(.{ .threads = 2 }, asyncMain, .{}));
}

fn asyncMain() !void {
    const frames = try allocator.alloc(@Frame(runner), num_tasks);
    defer allocator.free(frames);

    var lock = Lock{};
    var counter: u64 = 0;

    for (frames) |*frame, id|
        frame.* = async runner(&lock, &counter, id);

    for (frames) |*frame, id| {
        std.debug.warn("waiting on {}\n", .{id});
        await frame;
        std.debug.warn("{} completed\n", .{id});
    }

    // lock.acquireAsync();
    // defer lock.release();

    if (counter != num_tasks * num_iters)
        unreachable; // invalid counter result
}

fn runner(lock: *Lock, counter: *u64, id: usize) void {
    Task.runConcurrentlyAsync();

    var i: usize = num_iters;
    while (i != 0) : (i -= 1) {

        lock.acquireAsync();
        defer lock.release();

        counter.* += 1;
    }

    // std.debug.warn("{} finished on thread {}\n", .{id, std.Thread.getCurrentId()});
}