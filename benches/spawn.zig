const std = @import("std");
const zap = @import("zap");

const Task = zap.runtime.Task;
const allocator = std.heap.page_allocator;

const num_spawners = 10;
const num_tasks = 100_000;

pub fn main() !void {
    try (try Task.run(.{}, asyncMain, .{}));
}

fn asyncMain() !void {
    const frames = try allocator.alloc(@Frame(spawner), num_spawners);
    defer allocator.free(frames);

    var counter: usize = num_tasks * num_spawners;
    for (frames) |*frame|
        frame.* = async spawner(&counter);
    for (frames) |*frame|
        try (await frame);

    const count = @atomicLoad(usize, &counter, .Monotonic);
    if (count != 0)
        std.debug.panic("bad counter", .{});
}

fn spawner(counter: *usize) !void {
    Task.yield();

    const frames = try allocator.alloc(@Frame(runner), num_tasks);
    defer allocator.free(frames);

    for (frames) |*frame|
        frame.* = async runner(counter);
    for (frames) |*frame|
        await frame;
}

fn runner(counter: *usize) void {
    Task.runConcurrently();
    
    _ =  @atomicRmw(usize, counter, .Sub, 1, .Monotonic);
}
