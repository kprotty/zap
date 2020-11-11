const Z = @import("./z.zig");

const num_spawners = 10;
const num_tasks = 100_000;

pub fn main() !void {
    try Z.Task.runAsync(.{}, asyncMain, .{});
}

fn asyncMain() void {
    var wg = Z.WaitGroup.init(num_spawners * num_tasks);

    var i: usize = num_spawners;
    while (i > 0) : (i -= 1)
       Z.spawn(spawner, .{&wg});

    wg.wait();
}

fn spawner(wg: *Z.WaitGroup) !void {
    var i: usize = num_tasks;
    while (i > 0) : (i -= 1)
       Z.spawn(runner, .{wg});
}

fn runner(wg: *Z.WaitGroup) void {
    wg.done();
}
