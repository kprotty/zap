const std = @import("std");
const builtin = @import("builtin");

const Mode = builtin.Mode;
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const build_mode = b.standardReleaseOptions();

    // setup examples
    const example_step = b.step("examples", "Build examples");
    inline for ([_][]const u8 {
        "hello_world",
    }) |example_name| {
        const example = b.addExecutable(example_name, "examples/" ++ example_name ++ ".zig");
        example.addPackagePath("ziggo", "ziggo.zig");
        example.setBuildMode(build_mode);
        example_step.dependOn(&example.step);
    }

    // setup tests
    const test_all_step = b.step("test", "Run all tests in all modes");
    inline for ([_]Mode { Mode.Debug, Mode.ReleaseSafe, Mode.ReleaseFast, Mode.ReleaseSmall }) |mode| {
        const mode_str = switch (mode) {
            .Debug => "debug",
            .ReleaseSafe => "release-safe",
            .ReleaseFast => "release-fast",
            .ReleaseSmall => "release-small",
        };

        const tests = b.addTest("ziggo.zig");
        tests.setBuildMode(mode);
        tests.setNamePrefix(mode_str ++ " ");

        const test_step = b.step("test-" ++ mode_str, "Run all tests in " ++ mode_str ++ ".");
        test_step.dependOn(&tests.step);
        test_all_step.dependOn(test_step);
    }
}