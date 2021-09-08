const std = @import("std");
const Async = @import("async.zig");

const num_tasks = 100_000;
const num_iters = 10;

pub fn main() !void {
    try (try Async.run(asyncMain, .{}));
}

fn asyncMain() !void {
    try benchmark("single-producer", runSingleProducer);
    try benchmark("multi-producer", runMultiProducer);
    try benchmark("single-chain", runSingleChain);
    try benchmark("multi-chain", runMultiChain);
}

fn benchmark(comptime name: []const u8, comptime benchFn: anytype) !void {
    var timer = try std.time.Timer.start();
    var results: [num_iters]u64 = undefined;

    for (results) |*result| {
        const start = timer.read();
        try benchFn();
        const end = timer.lap();
        result.* = std.math.sub(u64, end, start) catch 0;
    }

    var sum: u64 = 0;
    for (results) |r| sum += r;
    var elapsed = @intToFloat(f64, sum) / @intToFloat(f64, results.len);

    var units: []const u8 = "ns";
    if (elapsed >= std.time.ns_per_s) {
        elapsed /= std.time.ns_per_s;
        units = "s";
    } else if (elapsed >= std.time.ns_per_ms) {
        elapsed /= std.time.ns_per_ms;
        units = "ms";
    } else if (elapsed >= std.time.ns_per_us) {
        elapsed /= std.time.ns_per_us;
        units = "us";
    }

    std.debug.warn("{s}\t... {d:.2}{s}\n", .{name, elapsed, units});
}

fn runSingleProducer() !void {
    const Worker = struct {
        fn run() void {
            Async.Task.fork();
            
            
            var i: usize = 10;
            while (i > 0) : (i -= 1) {
                std.os.sched_yield() catch unreachable;
            }
        }
    };

    const frames = try Async.allocator.alloc(@Frame(Worker.run), num_tasks);
    defer Async.allocator.free(frames);

    for (frames) |*f| f.* = async Worker.run();
    for (frames) |*f| await f;
} 

fn runMultiProducer() !void {
        
} 

fn runSingleChain() !void {
        
} 

fn runMultiChain() !void {
        
} 