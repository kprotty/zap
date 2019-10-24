const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.build.Builder) void {
    const entry_point = "zap.zig";
    const build_docs = b.addSystemCommand([_][]const u8 {
        b.zig_exe,
        "test",
        entry_point,
        "-femit-docs",
        "-fno-emit-bin",
        "--output-dir",
        ".",
    });

    const test_zap = b.addTest(entry_point);
    test_zap.setBuildMode(b.standardReleaseOptions());

    const test_step = b.step("test", "Run all tests & build docs");
    test_step.dependOn(&test_zap.step);
    test_step.dependOn(&build_docs.step);
}
