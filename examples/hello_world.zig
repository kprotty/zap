const std = @import("std");
const ziggo = @import("ziggo");

pub fn main() !void {
    try ziggo.runtime.run(ziggo.runtime.Config.default(), asyncMain);
}

fn asyncMain() void {
    std.debug.warn("Hello world\n");
}
