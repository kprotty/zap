const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const exe = b.addExecutable("example", "examples/example.zig");
    exe.setBuildMode(b.standardReleaseOptions());
    exe.addPackagePath("zio", "src/runtime.zig");
    switch (builtin.os) {
        .linux => {},
        .windows => exe.setTarget(builtin.arch, builtin.os, builtin.Abi.gnu),
        else => exe.linkSystemLibrary("c"),
    }

    const run_step = b.step("run", "Run example code");
    run_step.dependOn(&exe.run().step);
    exe.install();
}