const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    _ = b.addModule("zap", .{ .source = .{ .path = "src/thread_pool" } });
    _ = b.addModule("zap_go", .{ .source = .{ .path = "src/thread_pool_go_based" } });
}