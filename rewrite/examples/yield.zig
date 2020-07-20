const std = @import("std");
const zap = @import("zap");

const num_tasks = 100 * 1000;
const num_yields = 200;

pub fn main() !void {
    try (try zap.Scheduler.runAsync(.{}, asyncMain, .{}));
}

fn asyncMain() !void {
    const frames = try std.heap.page_allocator.alloc(@Frame(yielder), num_tasks);
    defer std.heap.page_allocator.free(frames);

    var counter: usize = 0;
    var task = zap.Task.init(@frame());

    suspend {
        for (frames) |*frame| {
            frame.* = async yielder(&counter, &task);
        }
    }
    
    if (@atomicLoad(usize, &counter, .SeqCst) != num_tasks)
        std.debug.panic("Bad counter\n", .{});
}

fn yielder(counter: *usize, task: *zap.Task) void {
    zap.Task.yield();

    var i: usize = num_yields;
    while (i != 0) : (i -= 1) {
        zap.Task.yield();
    }

    const count = @atomicRmw(usize, counter, .Add, 1, .SeqCst);
    if (count + 1 == num_tasks)
        task.schedule();
}

