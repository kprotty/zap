const std = @import("std");
const Async = @import("async.zig");

const num_tasks = 200_000; // zig can handle more, but we need to be nice to Golang ;^)
const num_producers = 10; // number of producers for the multi-producer benchmarks
const num_slots = 100; // channel buffer capacity for chan benchmarks

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

    // Measure the benchmark function
    const start = timer.read();
    try benchFn();
    const end = timer.lap();

    // Compute the amount of time taken
    var elapsed = try std.math.sub(u64, end, start);
    var units: []const u8 = "ns";

    // Convert them to nicer units
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

    std.debug.warn("{s}\t... {d}{s}\n", .{name, elapsed, units});
}

fn blackBox(value: anytype) @TypeOf(value) {
    var stub: @TypeOf(value) = undefined;
    @ptrCast(*volatile @TypeOf(value), &stub).* = value;
    return @ptrCast(*volatile @TypeOf(value), &stub).*;
}

// ===================================================================

fn runSpawnWork(batch: *Async.Batch) void {
    var task = Async.Task{ .frame = @frame() };
    suspend {
        batch.push(&task);
    }

    // Compute all divisors of 1000
    // Takes a micro second or two to complete.
    // Simulates a relatively average asynchronous task.
    const divisor = blackBox(@as(usize, 1000));
    
    var count: usize = 0;
    var i: usize = 2;
    while (i <= divisor / 2) : (i += 1) {
        count += @boolToInt(divisor % i == 0);
    }

    _ = blackBox(count);
}

fn runSpawnProducer(workers: []@Frame(runSpawnWork)) void {
    var batch = Async.Batch{};
    for (workers) |*worker| {
        worker.* = async runSpawnWork(&batch);
    }

    batch.schedule();
    for (workers) |*worker| {
        await worker;
    }
}

fn runSpawnSingleProducer() !void {
    const workers = try Async.allocator.alloc(@Frame(runSpawnWork), num_tasks);
    defer Async.allocator.free(workers);

    runSpawnProducer(workers);
} 

fn runSpawnMultiProducer() !void {
    const workers = try Async.allocator.alloc(@Frame(runSpawnWork), num_tasks);
    defer Async.allocator.free(workers);

    const producers = try Async.allocator.alloc(@Frame(runSpawnProducer), num_producers);
    defer Async.allocator.free(producers);

    const chunk_size = @divFloor(num_tasks, num_producers);
    for (producers) |*producer, i| {
        const worker_chunk = workers[(i * chunk_size)..][0..chunk_size];
        producer.* = async runSpawnProducer(worker_chunk);
    }

    for (producers) |*producer| {
        await producer;
    }
} 

// ===================================================================

const Chan = Async.Channel(u8, .Slice);

fn runChanAsync() void {
    var task = Async.Task{ .frame = @frame() };
    suspend {
        task.schedule();
    }
}

fn runChanProducer(chan: *Chan, count: usize) void {
    runChanAsync();

    var i = count;
    while (i > 0) : (i -= 1) {
        chan.send(0) catch unreachable;
    }
}

fn runChanConsumer(chan: *Chan) void {
    runChanAsync();

    while (true) {
        const x = chan.recv() catch break;
        std.debug.assert(x == 0);
    }
}

fn runChanSingleProducer() !void {
    const buffer = try Async.allocator.alloc(u8, num_slots);
    defer Async.allocator.free(buffer);

    var chan = Chan.init(buffer);
    defer chan.deinit();

    var consumer = async runChanConsumer(&chan);
    defer {
        chan.close();
        await consumer;
    }

    runChanProducer(&chan, num_tasks);
} 

fn runChanMultiProducer() !void {
    const buffer = try Async.allocator.alloc(u8, num_slots);
    defer Async.allocator.free(buffer);

    var chan = Chan.init(buffer);
    defer chan.deinit();

    var consumer = async runChanConsumer(&chan);
    defer {
        chan.close();
        await consumer;
    }

    const producers = try Async.allocator.alloc(@Frame(runChanProducer), num_producers);
    defer Async.allocator.free(producers);

    const chunk_size = num_tasks / num_producers;
    for (producers) |*producer, i| {
        const count = std.math.min(num_tasks - (i * chunk_size), chunk_size);
        producer.* = async runChanProducer(&chan, count);
    }

    for (producers) |*producer| {
        await producer;
    }
} 