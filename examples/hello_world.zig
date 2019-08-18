const ziggo = @import("ziggo");
const runtime = ziggo.runtime;
const std = @import("std");

pub fn main() !void {
    try runtime.run(runtime.Config.default(), start);
}

async fn start() void {
    std.debug.warn("Hello world\n");
}