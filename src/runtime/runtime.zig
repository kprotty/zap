
pub const Lock = @import("./lock.zig").Lock;
pub const Event = @import("./event.zig").Event;
pub const Thread = @import("./thread.zig").Thread;
pub const Allocator = @import("std").mem.Allocator;
pub const target = @import("./target.zig");
pub const scheduler = @import("./scheduler.zig");
pub const system = @import("./system/system.zig");
pub const nanotime = @import("./time.zig").nanotime;

pub const RunConfig = struct {
    run_forever: bool = false,
    default: scheduler.Pool.Config = .{
        .max_threads = null,
        .stack_size = 1 * 1024 * 1024,
    },
    blocking: scheduler.Pool.Config = .{
        .max_threads = 64,
        .stack_size = 64 * 1024,
    },
};

fn ReturnTypeOf(comptime asyncFn: anytype) type {
    return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
}

pub fn runAsync(config: RunConfig, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
    const Args = @TypeOf(args);
    const Result = ReturnTypeOf(asyncFn);
    const Decorator = struct {
        fn entry(fnArgs: Args, shutdown: bool, task: *scheduler.Task, result: *?Result) void {
            suspend {
                task.* = scheduler.Task.init(@frame());
            }

            const ret_val = @call(.{}, asyncFn, fnArgs);
            result.* = ret_val;

            suspend {
                if (shutdown) {
                    const worker = scheduler.Worker.getCurrent() orelse @panic("task resumed without a worker");
                    worker.getPool().shutdown();
                }
            }
        }
    };

    var result: ?Result = null;
    var task: scheduler.Task = undefined;
    var frame = async Decorator.entry(args, !config.run_forever, &task, &result);

    scheduler.Pool.run(config.default, &task);

    return result orelse error.DidNotComplete;
}

pub const SpawnConfig = struct {
    allocator: *Allocator,
    use_lifo: bool = true,
};

pub fn spawnAsync(config: SpawnConfig, comptime asyncFn: anytype, args: anytype) !void {
    @compileError("TODO");
}

pub fn yieldAsync() void {
    @compileError("TODO");
}

pub const AsyncEvent = struct {
    pub fn wait(self: *AsyncEvent, deadline: ?u64, condition: anytype) bool {
        @compileError("TODO");
    }

    pub fn notify(self: *AsyncEvent) void {
        @compileError("TODO");
    }
};