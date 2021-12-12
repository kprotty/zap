const std = @import("std");
const ThreadPool = @import("ThreadPool.zig");

const Timer = std.time.Timer;
const allocator = std.heap.page_allocator;

pub fn main() !void {
    try bench("serial", serial);
}

fn bench(
    comptime name: []const u8, 
    comptime func: fn([]ThreadPool.Runnable) void,
) !void {
    const concurrency = 10_000;
    const runnables = try allocator.alloc(ThreadPool.Runnable, concurrency);
    defer allocator.free(runnables);
    
    var timer = try std.time.Timer.start();
    const started = timer.read();
    defer {
        var unit: []const u8 = "ns";
        var elapsed = @intToFloat(f64, timer.read() - started);
        if (elapsed >= std.time.ns_per_s) {
            elapsed /= std.time.ns_per_s;
            unit = "s";
        } else if (elapsed >= std.time.ns_per_ms) {
            elapsed /= std.time.ns_per_ms;
            unit = "ms";
        } else if (elapsed >= std.time.ns_per_us) {
            elapsed /= std.time.ns_per_us;
            unit = "us";
        }
        std.debug.print("{}\t\t{d:>.2}{}\n", .{ name, elapsed, unit });
    }

    func(runnables);
}

fn serial(runnables: []ThreadPool.Runnable) void {
    
}