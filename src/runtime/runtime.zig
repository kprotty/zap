
pub const scheduler = @import("./internal/scheduler.zig");

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
                task.* = scheduler.Task.initAsync(@frame());
            }

            const ret_val = @call(.{}, asyncFn, fnArgs);
            result.* = ret_val;

            suspend {    
                if (shutdown) getCurrentWorker().getPool().shutdown();
            }
        }
    };

    var result: ?Result = null;
    var task: scheduler.Task = undefined;
    var frame = async Decorator.entry(args, !config.run_forever, &task, &result);

    scheduler.Pool.run(config.default, &task);

    return result orelse error.DidNotComplete;
}

pub fn getCurrentWorker() *scheduler.Worker {
    return scheduler.Worker.getCurrent() orelse {
        @panic("runtime.getCurrentWorker() called outside of a thread pool (scheduler.Pool)");
    };
}

pub fn yieldAsync() void {
    const worker = getCurrentWorker();
    const next_task = worker.poll() orelse return;

    suspend {
        var self = scheduler.Task.initAsync(@frame());
        worker.schedule(.next, next_task);
        worker.schedule(.fifo, &self);
    }
}

pub fn runConcurrentlyAsync() void {
    suspend {
        var self = scheduler.Task.initAsync(@frame());
        getCurrentWorker().schedule(.lifo, &self);
    }
}

pub fn spawnAsync(config: anytype, comptime asyncFn: anytype, args: anytype) !void {
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