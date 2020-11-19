const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});
    const libc = b.option(bool, "c", "Link libc") orelse false;
    const run = b.option(bool, "run", "Run the target example") orelse false;
    const single_threaded = b.option(bool, "single-threaded", "Assume program is single-threaded") orelse false;

    inline for (.{
        .{"yield", "yield.zig"},
        .{"http2", "http/http2.zig"},
    }) |example| {
        const zig_exe = b.addExecutable(example[0], example[1]);
        if (libc)
            zig_exe.linkLibC();

        zig_exe.addPackage(.{
            .name = "zap",
            .path = "../src/zap.zig",
        });

        zig_exe.single_threaded = single_threaded;
        zig_exe.setBuildMode(mode);
        zig_exe.setTarget(target);
        zig_exe.setOutputDir("zig-cache");
        zig_exe.install();

        const zig_step = b.step(example[0], "Build " ++ example[0] ++ " Zig example");
        zig_step.dependOn(&zig_exe.step);
        if (run)
            zig_step.dependOn(&zig_exe.run().step);
    }
}