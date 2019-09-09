const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();

    const test_all_step = b.step("test", "Run all tests");
    inline for ([_][]const u8 {
        "zio",
        "zync",
        // "zuma",
        // "zell",
    }) |module| {
        const tests = b.addTest(module ++ "/" ++ module ++ ".zig");
        // tests.setNamePrefix(module ++ " ");
        tests.setBuildMode(mode);

        const test_step = b.step("test-" ++ module, "Run all tests for " ++ module);
        test_step.dependOn(&tests.step);
        test_all_step.dependOn(test_step);
    }

    b.default_step.dependOn(test_all_step);
}