const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});
    const libc = b.option(bool, "c", "Link libc") orelse false;
    const run = b.option(bool, "run", "Run the target example") orelse false;

    inline for ([_][]const u8 {
        "yield",
        "spawn",
    }) |example| {
        const exe = b.addExecutable(example, example ++ ".zig");
        if (libc) exe.linkLibC();
        exe.setBuildMode(mode);
        exe.setTarget(target);
        exe.addPackagePath("zap", "../src/zap.zig");
        exe.setOutputDir("zig-cache");
        exe.install();

        const step = b.step(example, "Build " ++ example ++ " example");
        step.dependOn(&exe.step);
        if (run) {
            step.dependOn(&exe.run().step);
        }
    }
}