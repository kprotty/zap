const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.build.Builder) void {
    const build_mode = b.standardReleaseOptions();
    const packages = [_][]const u8 {
        "zync",
        "zuma",
        "zio",
        "zell",
    };

    const test_step = b.step("test", "Run all tests");
    inline for (packages) |package| {
        const test_package = b.addTest(package ++ "/" ++ package ++ ".zig");
        test_package.setBuildMode(build_mode);
        test_package.addPackagePath("zap", "zap.zig");
        test_step.dependOn(&test_package.step);
    }

    b.default_step.dependOn(test_step);
}