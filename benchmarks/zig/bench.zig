const std = @import("std");
const Async = @import("async.zig");

const num_tasks = 5_000_000; // zig can handle more, but we need to be nice to Golang ;^)
const num_samples = 10; // amount of times to run each benchmark
const num_concurrency = 10; // number of producers for the multi-producer benchmarks
const num_buffer_slots = 100; // channel buffer capacity for chan benchmarks

pub fn main() !void {
    try (try Async.run(asyncMain, .{}));
}

fn asyncMain() !void {
    try benchmark("spawn-spmc", runSpawnSingleProducer);
    try benchmark("spawn-mpmc", runSpawnMultiProducer);
    try benchmark("chan-spsc", runChanSingleProducer);
    try benchmark("chan-mpsc", runChanMultiProducer);
}

fn benchmark(comptime name: []const u8, comptime benchFn: anytype) !void {
    var timer = try std.time.Timer.start();
    var results: [num_samples]u64 = undefined;

    // Run the benchmark and collect elapsed times
    for (results) |*result| {
        const start = timer.read();
        try benchFn();
        const end = timer.lap();
        result.* = std.math.sub(u64, end, start) catch 0; // account for timer going backwards
    }

    // Average the elapsed times
    var sum: u64 = 0;
    for (results) |r| sum += r;
    var elapsed = @intToFloat(f64, sum) / @intToFloat(f64, results.len);

    // Convert them to nicer units
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

// ===================================================================

fn runWork() void {
    // Make this task run concurrently to the caller
    Async.Task.reschedule();

    // Takes a few micro seconds to complete.
    // Simulates a relatively average asynchronous task.
    _ = std.os.sched_yield() catch {};
}

fn runSpawner(frames: []@Frame(runWork)) void {
    // spawn all the frames given to this function (fork)
    for (frames) |*f| f.* = async runWork();
    // wait for all the frames to complete (join)
    for (frames) |*f| await f;
}

fn runSpawnSingleProducer() !void {
    // All the coroutines (Frames) can be allocated in batch given zig's async semantics
    const frames = try Async.allocator.alloc(@Frame(runWork), num_tasks);
    defer Async.allocator.free(frames);

    runSpawner(frames);
} 

fn runSpawnMultiProducer() !void {
    const frames = try Async.allocator.alloc(@Frame(runWork), num_tasks);
    defer Async.allocator.free(frames);

    const spawners = try Async.allocator.alloc(@Frame(runSpawner), num_concurrency);
    defer Async.allocator.free(spawners);

    const chunk_size = num_concurrency / num_tasks;
    for (spawners) |*s, i| s.* = async runSpawner(frames[(i * chunk_size)..][0..chunk_size]);
    for (spawners) |*s| await s;
} 

// ===================================================================

fn runChanSingleProducer() !void {
    
} 

fn runChanMultiProducer() !void {
        
} 