const std = @import("std");

pub const executor = @import("./executor.zig");
pub const Lock = @import("./lock.zig").Lock;
pub const Semaphore = @import("./semaphore.zig").Semaphore;

fn ReturnTypeOf(comptime asyncFn: anytype) type {
    return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
}

pub fn run(config: executor.Scheduler.RunConfig, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
    const Args = @TypeOf(args);
    const Decorator = struct {
        fn entry(task_ptr: *executor.Task, result_ptr: *?ReturnTypeOf(asyncFn), fn_args: Args) void {
            suspend {
                task_ptr.* = executor.Task.init(@frame());
            }
            const result = @call(.{}, asyncFn, fn_args);
            suspend {
                result_ptr.* = result;
                executor.Worker.getCurrent().?.getScheduler().shutdown();
            }
        }
    };

    var task: executor.Task = undefined;
    var result: ?ReturnTypeOf(asyncFn) = null;
    var frame = async Decorator.entry(&task, &result, args);

    try executor.Scheduler.run(config, task.toBatch());
    
    return result orelse error.DeadLocked;
}

pub fn schedule(batchable: anytype) void {
    const worker = executor.Worker.getCurrent() orelse {
        std.debug.panic("runtime.schedule() when not inside a runtime scheduler", .{});
    };
    worker.schedule(executor.Batch.from(batchable));
}

pub fn yield() void {
    const worker = executor.Worker.getCurrent() orelse {
        std.debug.panic("runtime.yield() when not inside a runtime scheduler", .{});
    };
    reschedule(worker);
}

fn reschedule(worker: *executor.Worker) void {
    suspend {
        var task = executor.Task.init(@frame());
        const batch = executor.Batch.from(&task);
        worker.schedule(batch);
    }
}

pub const SpawnConfig = struct {
    allocator: ?*std.mem.Allocator = null,
};

pub fn spawn(config: SpawnConfig, comptime asyncFn: anytype, args: anytype) !void {
    const Args = @TypeOf(args);
    const Decorator = struct {
        fn entry(allocator: *std.mem.Allocator, worker: *executor.Worker, fn_args: Args) void {
            reschedule(worker);
            _ = @call(.{}, asyncFn, fn_args);
            suspend {
                allocator.destroy(@frame());
            }
        }
    };

    const worker = executor.Worker.getCurrent() orelse {
        std.debug.panic("runtime.spawn() when not inside a runtime scheduler", .{});
    };

    const allocator = config.allocator orelse worker.getAllocator();
    var frame = try allocator.create(@Frame(Decorator.entry));
    frame.* = async Decorator.entry(allocator, worker, args);
}
