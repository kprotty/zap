const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    _ = b.addModule("zap", .{ .source_file = .{ .path = "src/thread_pool.zig" } });
    _ = b.addModule("zap_go", .{ .source_file = .{ .path = "src/thread_pool_go_based.zig" } });
}