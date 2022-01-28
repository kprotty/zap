const std = @import("std");
const ThreadPool = @import("ThreadPool.zig");
const SerialPool = @import("SerialPool.zig");

const Timer = std.time.Timer;
const allocator = std.heap.page_allocator;

const Atomic = std.atomic.Atomic;
const WaitGroup = struct {
    count: Atomic(usize) = Atomic(usize).init(0),
    futex: Atomic(u32) = Atomic(u32).init(0),

    fn add(self: *WaitGroup) void {
        _ = self.count.fetchAdd(1 << 1, .Monotonic);
    }

    fn done(self: *WaitGroup) void {
        const count = self.count.fetchSub(1 << 1, .AcqRel);
        if (count == ((1 << 1) | 1)) {
            self.futex.store(1, .Release);
            std.Thread.Futex.wake(&self.futex, 1);
        }
    }

    fn wait(self: *WaitGroup) void {
        var count = self.count.load(.Acquire);
        if ((count >> 1) > 0) {
            count = self.count.fetchAdd(1, .Acquire);
        }

        if ((count >> 1) > 0) {
            while (self.futex.load(.Acquire) == 0)
                std.Thread.Futex.wait(&self.futex, 0, null) catch unreachable;
        }
    }
};

pub fn main() !void {
    try bench("serial  ", SerialPool);
    try bench("threaded", ThreadPool);
}

fn bench(comptime name: []const u8, comptime Pool: type) !void {
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
        std.debug.print("{s} = {d:>.2}{s}\n", .{ name, elapsed, unit });
    }

    const Task = struct {
        runnable: Pool.Runnable = .{ .runFn = runFn },
        wg: *WaitGroup,

        fn runFn(runnable: *Pool.Runnable) void {
            const self = @fieldParentPtr(@This(), "runnable", runnable);
            defer self.wg.done();

            // TODO: work here
            std.os.sched_yield() catch {};
        } 
    };

    const num_cpus = try std.Thread.getCpuCount();
    const max_threads = try std.math.cast(u8, num_cpus);
    var pool = Pool.init(.{ .max_threads = max_threads });
    defer {
        pool.shutdown();
        pool.join();
    }

    const tasks = try allocator.alloc(Task, 100_000);
    defer allocator.free(tasks);

    var wg = WaitGroup{};
    var batch = Pool.Batch{};
    for (tasks) |*task| {
        wg.add();
        task.* = .{ .wg = &wg };
        batch.push(Pool.Batch.from(&task.runnable));
    }

    pool.schedule(batch);

    if (@hasDecl(Pool, "run")) pool.run();
    wg.wait();
}


