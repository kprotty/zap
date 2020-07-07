const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});
    const libc = b.option(bool, "c", "Link libc") orelse false;
    const run = b.option(bool, "run", "Run the target example") orelse false;

    const libzap = b.addStaticLibrary("libzap", "../src/c/zap.zig");
    libzap.linkLibC();
    libzap.setBuildMode(mode);
    libzap.setTarget(target);
    libzap.addPackagePath("zap", "../src/zap.zig");
    libzap.setOutputDir("zig-cache");

    inline for ([_][]const u8 {
        "yield",
        "spawn",
    }) |example| {
        const zig_exe = b.addExecutable(example, example ++ ".zig");
        if (libc)
            zig_exe.linkLibC();
        zig_exe.setBuildMode(mode);
        zig_exe.setTarget(target);
        zig_exe.addPackagePath("zap", "../src/zap.zig");
        zig_exe.setOutputDir("zig-cache");
        zig_exe.install();

        const zig_step = b.step(example, "Build " ++ example ++ " Zig example");
        zig_step.dependOn(&zig_exe.step);
        if (run)
            zig_step.dependOn(&zig_exe.run().step);

        const c_exe = b.addExecutable(example ++ "_c", null);
        c_exe.linkLibC();
        c_exe.addCSourceFile(example ++ ".c", &[_][]const u8{});
        c_exe.addIncludeDir("../src/c/");
        c_exe.linkLibrary(libzap);
        c_exe.setBuildMode(mode);
        c_exe.setTarget(target);
        c_exe.setOutputDir("zig-cache");
        c_exe.install();

        const c_step = b.step(example ++ "_c", "Build " ++ example ++ " C example");
        c_step.dependOn(&c_exe.step);
        if (run)
            c_step.dependOn(&c_exe.run().step);
    }
}