const std = @import("std");
const Loop = @import("src/s3.zig");

pub fn main() !void {
    try (try Loop.run(asyncMain, .{}));
}

fn asyncMain() !void {
    std.debug.print("Hello World\n", .{});
}