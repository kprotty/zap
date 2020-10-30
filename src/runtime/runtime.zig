const std = @import("std");
const zap = @import("../zap.zig");

const core = zap.core;

pub const Task = @import("./task.zig").Task;

pub const sync = struct {
    pub const atomic = core.sync.atomic;

    pub const OsFutex = @import("./futex.zig").OsFutex;

    pub const Lock = extern struct {
        lock: core.sync.Lock = core.sync.Lock{},

        pub fn tryAcquire(self: *Lock) void {
            return self.lock.tryAcquire();
        }

        pub fn acquire(self: *Lock) void {
            self.lock.acquire(OsFutex);
        }

        pub fn acquireAsync(self: *Lock) void {
            self.lock.acquire(AsyncFutex);
        }

        pub fn release(self: *Lock) void {
            self.lock.release();
        }
    };
};