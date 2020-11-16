const std = @import("std");

pub const executor = @import("./executor.zig");
pub const Lock = @import("./lock.zig").Lock;

fn ReturnTypeOf(comptime asyncFn: anytype) type {
    return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
}

pub const RunConfig = struct {
    max_threads: ?u16 = null,
};

pub fn run(config: RunConfig, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
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

    executor.Scheduler.run(
        executor.Scheduler.RunConfig{ .max_threads = config.max_threads },
        task.toBatch(),
    );
    
    return result orelse error.DeadLocked;
}

pub fn getWorker() *executor.Worker {
    return executor.Worker.getCurrent() orelse {
        std.debug.panic("runtime.getWorker() called when not inside a runtime scheduler thread", .{});
    };
}

pub fn schedule(batchable: anytype, hints: executor.Worker.ScheduleHints) void {
    getWorker().schedule(executor.Batch.from(batchable), hints);
}

pub fn reschedule(hints: executor.Worker.ScheduleHints) void {
    suspend {
        var task = executor.Task.init(@frame());
        schedule(&task, hints);
    }
}

pub fn yield() void {
    reschedule(.{});
}

pub const SpawnConfig = struct {
    allocator: ?*std.mem.Allocator = null,
};

pub fn spawn(config: SpawnConfig, comptime asyncFn: anytype, args: anytype) !void {
    const Args = @TypeOf(args);
    const Decorator = struct {
        fn entry(allocator: *std.mem.Allocator, fn_args: Args) void {
            reschedule(.{ .use_lifo = true });
            _ = @call(.{}, asyncFn, fn_args);
            suspend {
                allocator.destroy(@frame());
            }
        }
    };

    const allocator = config.allocator orelse getWorker().getAllocator();
    var frame = try allocator.create(@Frame(Decorator.entry));
    frame.* = async Decorator.entry(allocator, args);
}
