const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});
    const link_c = b.option(bool, "c", "link libc") orelse false;

    const exe = b.addExecutable("bench", "src/bench.zig");
    if (link_c) {
        exe.linkLibC();
    }

    exe.addPackage(.{
        .name = "thread_pool",
        .path = .{ .path = "../../src/thread_pool.zig" },
    });
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run = b.step("run", "Run the benchmark");
    run.dependOn(&exe.run().step);
}