const std = @import("std");
const Async = @import("async.zig");

const SIZE = 128_000;

pub fn main() void {
    return Async.run(asyncMain, .{});
}

fn asyncMain() void {
    const arr = Async.allocator.alloc(i32, SIZE) catch @panic("failed to allocate array");
    defer Async.allocator.free(arr);

    std.debug.warn("shuffling\n", .{});
    shuffle(arr);

    std.debug.warn("running\n", .{});
    var timer = std.time.Timer.start() catch @panic("failed to create os timer");
    quickSort(arr);

    var elapsed = @intToFloat(f64, timer.lap());
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

    std.debug.warn("took {d:.2}{s}\n", .{ elapsed, units });
    if (!verify(arr)) {
        std.debug.panic("array not sorted", .{});
    }
}

fn verify(arr: []const i32) bool {
    for (arr[1..]) |item, i| {
        if (item < arr[i])
            return false;
    }
    return true;
}

fn shuffle(arr: []i32) void {
    var xs: u32 = 0xdeadbeef;
    for (arr) |_, i| {
        xs ^= xs << 13;
        xs ^= xs >> 17;
        xs ^= xs << 5;
        const j = xs % (i + 1);
        std.mem.swap(i32, &arr[i], &arr[j]);
    }
}

fn partition(arr: []i32) usize {
    var i: usize = 0;
    const p = arr.len - 1;
    const pivot = arr[p];
    for (arr) |x, j| {
        if (x < pivot) {
            std.mem.swap(i32, &arr[j], &arr[i]);
            i += 1;
        }
    }
    std.mem.swap(i32, &arr[i], &arr[p]);
    return i;
}

fn quickSort(arr: []i32) void {
    if (arr.len <= 32) {
        selectionSort(arr);
    } else {
        const p = partition(arr);
        const low = arr[0..p];
        const high = arr[p+1..];

        var left: ?Async.JoinHandle(void) = null;
        if (low.len > 0) {
            left = Async.spawn(quickSort, .{low});
        }

        var right: ?Async.JoinHandle(void) = null;
        if (high.len > 0) {
            right = Async.spawn(quickSort, .{high});
        }

        if (left) |l| l.join();
        if (right) |r| r.join();
    }
}

fn selectionSort(arr: []i32) void {
    for (arr) |_, i| {
        var min = i;
        for (arr[i..]) |_, j| {
            if (arr[j] < arr[min]) {
                min = j;
            }
        }
        if (min != i) {
            std.mem.swap(i32, &arr[i], &arr[min]);
        }
    }
}
