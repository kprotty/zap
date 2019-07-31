const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const build_mode = b.standardReleaseOptions();

    const example_step = b.step("examples", "Build examples");
    inline for ([_][]const u8 {
        "hello_world",
    }) |example_name| {
        const example = b.addExecutable(example_name, "examples/" ++ example_name ++ ".zig");
        example.addPackagePath("zio", "zio.zig");
        example.setBuildMode(build_mode);
        example_step.dependOn(&example.step);
    }
}