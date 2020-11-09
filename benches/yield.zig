const std = @import("std");
const zap = @import("zap");

const Task = zap.runtime.Task;
const Heap = @import("./allocator.zig").Allocator;

const num_tasks = 100_000;
const num_yields = 100;

pub fn main() !void {
    var heap: Heap = undefined;
    try heap.init();
    defer heap.deinit();

    try (try Task.runAsync(.{}, asyncMain, .{heap.getAllocator()}));
}

fn asyncMain(allocator: *std.mem.Allocator) !void {
    const frames = try allocator.alloc(@Frame(yielder), num_tasks);
    defer allocator.free(frames);

    var counter: usize = num_tasks;
    for (frames) |*frame| 
        frame.* = async yielder(&counter);
    for (frames) |*frame|
        await frame;

    const count = @atomicLoad(usize, &counter, .Monotonic);
    if (count != 0)
        std.debug.panic("bad counter", .{});
}

fn yielder(counter: *usize) void {
    Task.runConcurrentlyAsync();

    var i: usize = num_yields;
    while (i != 0) : (i -= 1) {
        Task.yieldAsync();
    }

    _ = @atomicRmw(usize, counter, .Sub, 1, .Monotonic);
}