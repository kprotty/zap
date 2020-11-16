const std = @import("std");
const zap = @import("zap");

const runtime = zap.runtime;
const WaitGroup = zap.sync.WaitGroup;

const num_tasks = 100_000;
const num_yields = 100;

pub fn main() !void {
    try runtime.run(.{}, asyncMain, .{});
}

fn asyncMain() void {
    var wg = WaitGroup.init(num_tasks);

    for ([_]u0{0} ** num_tasks) |_|
        runtime.spawn(.{}, yielder, .{&wg}) catch unreachable;

    wg.wait();
}

fn yielder(wg: *WaitGroup) void {
    defer wg.done();

    for ([_]u8{0} ** num_yields) |_, y|
        runtime.yield();
}
