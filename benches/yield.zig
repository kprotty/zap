const std = @import("std");
const zap = @import("zap");

const Task = zap.Task;
const allocator = std.heap.page_allocator;

const num_tasks = 100_000;
const num_yields = 100;

pub fn main() !void {
    try (try Task.run(.{}, asyncMain, .{}));
}

fn asyncMain() !void {
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
    Task.runConcurrently();

    var i: usize = num_yields;
    while (i != 0) : (i -= 1) {
        Task.yield();
    }

    _ = @atomicRmw(usize, counter, .Sub, 1, .Monotonic);
}