const std = @import("std");
const zap = @import("zap");

pub fn main() !void {
    try zap.runtime.runAsync(.{}, asyncMain, .{});
}

fn asyncMain() void {
    std.debug.warn("hello world\n", .{});
}