const std = @import("std");
const Z = @import("./src/scheduler.zig");

pub fn main() !void {
    var task = Z.Task.init(.Normal, struct {
        fn callback(t: *Z.Task, ctx: *Z.Task.Context) callconv(.C) ?*Z.Task {
            std.debug.warn("Hello world\n", .{});
            ctx.shutdown();
            return null;
        }
    }.callback);

    const builder = Z.Builder{};
    try builder.run(&task);
}