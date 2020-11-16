const std = @import("std");
const runtime = @import("../runtime/runtime.zig");

const Lock = runtime.Lock;
const Task = runtime.executor.Task;

pub const WaitGroup = struct {
    lock: Lock = Lock{},
    count: usize,
    waiter: ?*Task = null,

    pub fn init(count: usize) WaitGroup {
        return WaitGroup{ .count = count };
    }

    pub fn done(self: *WaitGroup) void {
        const waiter = blk: {
            self.lock.acquire();
            defer self.lock.release();

            self.count -= 1;
            if (self.count != 0)
                return;
            break :blk self.waiter;
        };

        const task = waiter orelse return;
        runtime.schedule(task, .{ .use_lifo = true });
    }

    pub fn wait(self: *WaitGroup) void {
        self.lock.acquire();

        if (self.count == 0)
            return self.lock.release();

        suspend {
            var task = Task.init(@frame());
            self.waiter = &task;
            self.lock.release();
        }
    }
};