const std = @import("std");
const zap = @import("zap");

const num_spawners = 10;
const num_tasks_per_spawner = 500 * 1000;
const num_tasks = num_tasks_per_spawner * num_spawners;

pub fn main() !void {
    const counters = try std.heap.page_allocator.alloc(Counter, num_tasks);
    defer std.heap.page_allocator.free(counters);
    
    const spawners = try std.heap.page_allocator.alloc(Spawner, num_spawners);
    defer std.heap.page_allocator.free(spawners);

    var root = Root{
        .spawners = spawners,
        .counters = counters,
    };
    try zap.Scheduler.run(.{}, &root.runnable);
    if (!@atomicLoad(bool, &root.completed, .SeqCst))
        return error.DeadLocked;
}

const Root = struct {
    runnable: zap.Runnable = zap.Runnable.init(run),
    spawned: usize = 0,
    completed: bool = false,
    spawners: ?[]Spawner,
    counters: []Counter,

    fn run(runnable: *zap.Runnable) callconv(.C) void {
        const self = @fieldParentPtr(Root, "runnable", runnable);

        if (self.spawners) |_spawners| {
            const spawners = _spawners;
            self.spawners = null;
            self.runnable = zap.Runnable.init(run);

            var batch = zap.Runnable.Batch{};
            for (spawners) |*spawner, i| {
                defer batch.push(&spawner.runnable);
                const counters = self.counters[(i * num_tasks_per_spawner)..];
                const counters_end = std.math.min(num_tasks_per_spawner, counters.len);
                spawner.* = Spawner{
                    .counters = counters[0..counters_end],
                    .root = self,
                };
            }

            batch.schedule();
            return;
        }

        const task_spawned = @atomicLoad(usize, &self.spawned, .SeqCst);
        if (task_spawned != num_tasks) {
            std.debug.panic("Bad spawned count", .{});
        } else {
            @atomicStore(bool, &self.completed, true, .SeqCst);
        }
    }
};

const Spawner = struct {
    runnable: zap.Runnable = zap.Runnable.init(run),
    counters: []Counter,
    root: *Root,

    fn run(runnable: *zap.Runnable) callconv(.C) void {
        const self = @fieldParentPtr(Spawner, "runnable", runnable);

        var batch = zap.Runnable.Batch{};
        for (self.counters) |*counter| {
            defer batch.push(&counter.runnable);
            counter.* = Counter{ .root = self.root };
        }
        batch.schedule();
    }
};

const Counter = struct {
    runnable: zap.Runnable = zap.Runnable.init(run),
    root: *Root,

    fn run(runnable: *zap.Runnable) callconv(.C) void {
        const self = @fieldParentPtr(Counter, "runnable", runnable);
        const root = self.root;

        const spawned_count = @atomicRmw(usize, &root.spawned, .Add, 1, .SeqCst);
        if (spawned_count == num_tasks - 1) {
            root.runnable.schedule();
        }
    }
};