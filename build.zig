const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const shared = struct {
        mode: std.builtin.Mode,
        target: std.zig.CrossTarget,
        libc: bool,
        single_threaded: bool,

        fn apply(self: @This(), step: *std.build.LibExeObjStep) void {
            if (self.libc) step.linkLibC();
            step.single_threaded = self.single_threaded;
            step.setBuildMode(self.mode);
            step.setTarget(self.target);
        }
    } {
        .mode = b.standardReleaseOptions(),
        .target = b.standardTargetOptions(.{}),
        .libc = b.option(bool, "c", "Link libc") orelse false,
        .single_threaded = b.option(bool, "single-threaded", "Assume program is single-threaded") orelse false,
    };

    if (b.option([]const u8, "bench", "benchmark to build")) |benchmark| {
        const benchmarks = .{
            "yield",
        };

        const path = blk: {
            var path: ?[]const u8 = null;
            inline for (benchmarks) |valid_benchmark| {
                if (std.mem.eql(u8, benchmark, valid_benchmark))
                    path = "benches/" ++ valid_benchmark ++ ".zig";
            }
            break :blk path orelse std.debug.panic("invalid benchmark: {}\n", .{benchmark});
        };

        const exe = b.addExecutable(benchmark, path);
        exe.addPackage(.{
            .name = "zap",
            .path = "src/zap.zig",
        });

        shared.apply(exe);
        exe.install();

        if (b.option(bool, "run", "run the given benchmark") orelse false)
            b.default_step.dependOn(&exe.run().step);
    }
}