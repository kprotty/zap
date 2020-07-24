const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});
    const libc = b.option(bool, "c", "Link libc") orelse false;

    const zig_exe = b.addExecutable("yield", "yield/zap.zig");
    if (libc) zig_exe.linkLibC();
    zig_exe.setBuildMode(mode);
    zig_exe.setTarget(target);
    zig_exe.addPackagePath("zap", "../src/zap.zig");
    zig_exe.setOutputDir("zig-cache");
    zig_exe.install();

    const zig_step = b.step("yield", "Build the yield benchmark");
    zig_step.dependOn(&zig_exe.step);
}