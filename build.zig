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
}