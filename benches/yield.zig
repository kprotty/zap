const std = @import("std");
const zap = @import("zap");

pub fn main() !void {
    try (try zap.runtime.runAsync(.{}, asyncMain, .{}));
}

fn asyncMain() !void {
    const num_tasks = 50;
    const num_yields = 100;

    const Yielder = struct {
        fn run() void {
            zap.runtime.runConcurrentlyAsync();

            var i: usize = num_yields;
            while (i > 0) : (i -= 1) {
                zap.runtime.yieldAsync();
            }
        }
    };

    const allocator = std.heap.page_allocator;
    const frames = try allocator.alloc(@Frame(Yielder.run), num_tasks);
    defer allocator.free(frames);

    for (frames) |*frame|
        frame.* = async Yielder.run();
    for (frames) |*frame|
        await frame;

    std.debug.warn("done\n", .{});
}