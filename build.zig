const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // A group of shared settings that can be applied to any LibExeObjStep (for future use)
    const shared = struct {
        libc: bool,
        single_threaded: bool,
        mode: std.builtin.Mode,
        target: std.zig.CrossTarget,

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

    if (b.option([]const u8, "bench", "The benchmark to build")) |benchmark| {
        // TODO: add benchmarks here
        const benchmarks = .{};

        // Find th benchmark using comptime as bufPrint() doesn't seem to work for concat.
        const path = blk: {
            var path: ?[]const u8 = null;
            inline for (benchmarks) |valid_benchmark| {
                if (std.mem.eql(u8, benchmark, valid_benchmark))
                    path = "benches/" ++ valid_benchmark ++ ".zig";
            }
            break :blk path orelse std.debug.panic("Invalid benchmark: {}\n", .{benchmark});
        };

        // Create the benchmark executable step
        const exe = b.addExecutable(benchmark, path);
        exe.addPackage(.{
            .name = "zap",
            .path = "src/zap.zig",
        });
        shared.apply(exe);
        exe.install();

        // Optionally run the benchmark after creation
        if (b.option(bool, "run", "run the given benchmark") orelse false)
            b.default_step.dependOn(&exe.run().step);
    }
}