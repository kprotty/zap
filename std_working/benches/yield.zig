const Z = @import("./z.zig");

const num_tasks = 100_000;
const num_yields = 100;

pub fn main() !void {
    try Z.Task.runAsync(.{}, asyncMain, .{});
}

fn asyncMain() void {
    var wg = Z.WaitGroup.init(num_tasks);

    var i: usize = num_tasks;
    while (i > 0) : (i -= 1)
        Z.spawn(yielder, .{&wg});

    wg.wait();
}

fn yielder(wg: *Z.WaitGroup) void {
    defer wg.done();

    var i: usize = num_yields;
    while (i != 0) : (i -= 1)
        Z.Task.yieldAsync();
}