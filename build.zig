const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.build.Builder) void {
    const test_zap = b.addTest("zap.zig");
    test_zap.addPackagePath("zap", "zap.zig");
    test_zap.setBuildMode(b.standardReleaseOptions());
    
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&test_zap.step);
    b.default_step.dependOn(test_step);
}