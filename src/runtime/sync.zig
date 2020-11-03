const zap = @import("../zap.zig");

const core = zap.core;

pub const atomic = core.sync.atomic;

pub const OsFutex = zap.platform.Futex;
pub const AsyncFutex = zap.runtime.Task.AsyncFutex;

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