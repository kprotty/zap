const std = @import("std");
const ziggo = @import("ziggo");

const num_tasks = 100_000;
const num_yields = 100;

pub fn main() !void {
    try ziggo.runtime.run(.{}, asyncMain, .{});
}

fn asyncMain() void {
    var wg = ziggo.sync.WaitGroup.init(num_tasks);

    for ([_]u0{0} ** num_tasks) |_|
        ziggo.runtime.spawn(.{}, yielder, .{&wg}) catch unreachable;

    wg.wait();
}

fn yielder(wg: *ziggo.sync.WaitGroup) void {
    defer wg.done();

    for ([_]u8{0} ** num_yields) |_, y|
        ziggo.runtime.yield();
}
