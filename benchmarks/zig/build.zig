const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const link_c = b.option(bool, "c", "link libc") orelse false;

    const exe = b.addExecutable(.{
        .name = "qsort",
        .root_source_file = .{ .path = "qsort.zig" },
        .optimize = optimize,
        .target = target
    });
    if (link_c) {
        exe.linkLibC();
    }

    exe.addModule("thread_pool", b.createModule(.{
        .source_file = .{ .path = "../../src/thread_pool.zig" }
    }));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}