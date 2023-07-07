const std = @import("std");
const Async = @import("async.zig");

const SIZE = 10_000_000;

pub fn main() void {
    return Async.run(asyncMain, .{});
}

fn asyncMain() void {
    const arr = Async.allocator.alloc(i32, SIZE) catch @panic("failed to allocate array");
    defer Async.allocator.free(arr);

    std.debug.print("filling\n", .{});
    for (arr, 0..) |*item, i| {
        item.* = @intCast(i32, i);
    }

    std.debug.print("shuffling\n", .{});
    shuffle(arr);

    std.debug.print("running\n", .{});
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

    std.debug.print("took {d:.2}{s}\n", .{ elapsed, units });
    if (!verify(arr)) {
        std.debug.panic("array not sorted", .{});
    }
}

fn verify(arr: []const i32) bool {
    var i: usize = 0;
    while (true) : (i += 1) {
        if (i == arr.len - 1) return true;
        if (arr[i] > arr[i + 1]) return false;
    }
}

fn shuffle(arr: []i32) void {
    var xs: u32 = 0xdeadbeef;
    for (arr, 0..) |_, i| {
        xs ^= xs << 13;
        xs ^= xs >> 17;
        xs ^= xs << 5;
        const j = xs % (i + 1);
        std.mem.swap(i32, &arr[i], &arr[j]);
    }
}

fn quickSort(arr: []i32) void {
    if (arr.len <= 32) {
        insertionSort(arr);
    } else {
        const mid = partition(arr);

        var left = Async.spawn(quickSort, .{arr[0..mid]});
        var right = Async.spawn(quickSort, .{arr[mid..]});

        left.join();
        right.join();
    }
}

fn partition(arr: []i32) usize {
    const pivot = arr.len - 1;
    var i: usize = 0;
    for (arr[0..pivot], 0..) |_, j| {
        if (arr[j] <= arr[pivot]) {
            std.mem.swap(i32, &arr[j], &arr[i]);
            i += 1;
        }
    }
    std.mem.swap(i32, &arr[i], &arr[pivot]);
    return i;
}

fn insertionSort(arr: []i32) void {
    for (arr[1..], 0..) |_, i| {
        var n = i + 1;
        while (n > 0 and arr[n] < arr[n - 1]) {
            std.mem.swap(i32, &arr[n], &arr[n - 1]);
            n -= 1;
        }
    }
}
