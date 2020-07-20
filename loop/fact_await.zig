const std = @import("std");
const Task = @import("./src/task.zig").Task;
const bench_allocator = @import("./bench_allocator.zig");

const BigInt = std.math.big.int.Managed;
const allocator = bench_allocator.allocator;

// Uncomment to use std.event.Loop
// pub const io_mode = .evented;

const use_event_loop = @hasDecl(@import("root"), "io_mode");

pub fn main() !void {
    // Change scale and max memory here
    const N = 10000;
    try bench_allocator.initCapacity(64 * 1024 * 1024);

    if (use_event_loop) {
        try fact(N);
    } else {
        const result = try Task.Scheduler.run(.{}, fact, .{N});
        try result;
    }
}

fn fact(n: u64) !void {
    var x = try BigInt.init(allocator);
    defer x.deinit();
    return bigIntMultRange(&x, 1, n);
}

fn bigIntMultRange(out: *BigInt, a: u64, b: u64) anyerror!void {
    if (a == b) {
        try out.set(a);
        return;
    }

    if (use_event_loop) {
        std.event.Loop.startCpuBoundOperation();
    } else {
        Task.yield();
    }

    var l = try BigInt.init(allocator);
    defer l.deinit();
    var r = try BigInt.init(allocator);
    defer r.deinit();

    const m = @divFloor((a + b), 2);

    const frame_l = try allocator.create(@Frame(bigIntMultRange));
    defer allocator.destroy(frame_l);
    const frame_r = try allocator.create(@Frame(bigIntMultRange));
    defer allocator.destroy(frame_r);

    frame_l.* = async bigIntMultRange(&l, a, m);
    frame_r.* = async bigIntMultRange(&r, m + 1, b);

    const res_l = await frame_l;
    const res_r = await frame_r;

    try res_l;
    try res_r;

    try out.mul(l.toConst(), r.toConst());
}