const std = @import("std");
const zap = @import("./src/zap.zig");

pub fn main() !void {
    try (try zap.Task.run(.{}, asyncMain, .{}));
}

fn asyncMain() callconv(.Async) !void {
    std.debug.warn("Hello world\n", .{});
}