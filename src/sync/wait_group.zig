const std = @import("std");
const Lock = @import("../runtime/lock.zig").Lock;
const runtime = @import("../runtime/runtime.zig");

pub const WaitGroup = struct {
    lock: Lock = Lock{},
    count: usize,
    waiter: ?anyframe = null,

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

        if (waiter) |frame|
            runtime.schedule(frame);
    }

    pub fn wait(self: *WaitGroup) void {
        self.lock.acquire();

        if (self.count == 0)
            return self.lock.release();

        suspend {
            self.waiter = @frame();
            self.lock.release();
        }
    }
};