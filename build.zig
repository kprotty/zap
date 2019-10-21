const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.build.Builder) void {
    const test_zap = b.addTest("zap.zig");
    test_zap.setBuildMode(b.standardReleaseOptions());

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&test_zap.step);
}

fn buildDocs(b: *std.build.Builder) void {
    const test_step = b.step("test", "Run all tests & generate docs");
    test_step.dependOn(&b.addSystemCommand([_][]const u8{
        b.zig_exe,
        "test",
        "zap.zig",
        "-femit-docs",
        "--output-dir",
        "zig-cache",
    }).step);

    const docs_step = b.addExecutable("docs", "docs.zig");
    if (builtin.os != .windows)
        docs_step.linkSystemLibrary("c");
    test_step.dependOn(&docs_step.step);
    test_step.dependOn(&docs_step.run().step);
}
