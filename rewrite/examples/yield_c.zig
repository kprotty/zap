const std = @import("std");
const zap = @import("zap");

const num_tasks = 100 * 1000;
const num_yields = 200;

pub fn main() !void {
    const tasks = try std.heap.page_allocator.alloc(Task, num_tasks);
    defer std.heap.page_allocator.free(tasks);

    var root = Root{ .tasks = tasks };
    try zap.Scheduler.run(.{}, &root.runnable);

    if (!@atomicLoad(bool, &root.completed, .SeqCst)) {
        const counter = @atomicLoad(usize, &root.counter, .SeqCst);
        std.debug.print("Deadlocked with {}\n", .{counter});
        return error.DeadLocked;
    }
}

const Root = struct {
    runnable: zap.Runnable = zap.Runnable.init(run),
    completed: bool = false,
    counter: usize = 0,
    tasks: ?[]Task,

    fn run(runnable: *zap.Runnable) callconv(.C) void {
        const self = @fieldParentPtr(Root, "runnable", runnable);

        if (self.tasks) |tasks| {
            var batch = zap.Runnable.Batch{};
            for (tasks) |*task| {
                task.* = Task{ .root = self };
                batch.push(&task.runnable);
            }

            self.tasks = null;
            self.runnable = zap.Runnable.init(run);
            batch.schedule();
            return;
        }

        if (@atomicLoad(usize, &self.counter, .Monotonic) != num_tasks) {
            std.debug.panic("Bad counter\n", .{});
        } else {
            @atomicStore(bool, &self.completed, true, .SeqCst);
        }
    }
};

const Task = struct {
    runnable: zap.Runnable = zap.Runnable.init(run),
    yielded: usize = num_yields,
    root: *Root,

    fn run(runnable: *zap.Runnable) callconv(.C) void {
        const self = @fieldParentPtr(Task, "runnable", runnable);

        if (self.yielded != 0) {
            self.yielded -= 1;
            self.runnable = zap.Runnable.init(run);
            self.runnable.schedule();
            return;
        }

        const root = self.root;
        if (@atomicRmw(usize, &root.counter, .Add, 1, .Monotonic) + 1 == num_tasks)
            root.runnable.schedule();
    }
};
