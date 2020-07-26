const std = @import("std");
const Task = @import("./zap.zig").Task;

const num_tasks = 1000;
const num_yields = 10 * 1000;

pub fn main() !void {
    try (try Task.run(.{}, asyncMain, .{}));
}

fn asyncMain() !void {
    const allocator = std.heap.page_allocator;
    const frames = try allocator.alloc(@Frame(yielder), num_tasks);
    defer allocator.free(frames);

    var completed: usize = 0;
    var resume_task = Task.init(@frame());

    suspend {
        var batch = Task.Batch{};
        for (frames) |*frame|
            frame.* = async yielder(&batch, &resume_task, &completed);
        batch.schedule(.lifo);
    }

    const tasks_completed = @atomicLoad(usize, &completed, .Monotonic);
    if (tasks_completed != num_tasks)
        std.debug.panic("Not all tasks finished yielding", .{});
}

fn yielder(batch: *Task.Batch, main_task: *Task, completed: *usize) void {
    var resume_task = Task.init(@frame());
    suspend batch.push(&resume_task);

    var yields: usize = num_yields;
    while (yields != 0) : (yields -= 1) {
        resume_task = Task.init(@frame());
        suspend resume_task.schedule(.fifo);
    }

    suspend {
        const tasks_completed = @atomicRmw(usize, completed, .Add, 1, .Monotonic);
        if (tasks_completed + 1 == num_tasks)
            main_task.schedule(.lifo);
    }
}
