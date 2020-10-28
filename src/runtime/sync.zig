const std = @import("std");
const zap = @import("../zap.zig");
const core = zap.core;

pub const atomic = core.sync.atomic;

const futex = @import("./futex.zig");
pub const OsFutex = futex.OsFutex;
pub const AsyncFutex = futex.AsyncFutex;

pub fn yieldCpu() void {
    atomic.spinLoopHint();
}

pub fn yieldThread() void {
    Futex.yield(null);
}

pub const Lock = extern struct {
    lock: core.sync.Lock = core.sync.Lock{},

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

pub const AutoResetEvent = extern struct {
    event: core.sync.AutoResetEvent = core.sync.AutoResetEvent{},

    pub fn wait(self: *AutoResetEvent) void {
        self.event.wait(OsFutex);
    }

    pub fn waitAsync(self: *AutoResetEvent) void {
        self.event.wait(AsyncFutex);
    }

    pub fn timedWait(self: *AutoResetEvent) error{TimedOut}!void {
        self.event.timedWait(OsFutex);
    }

    pub fn timedWaitAsync(self: *AutoResetEvent) error{TimedOut}!void {
        self.event.timedWait(AsyncFutex);
    }

    pub fn set(self: *AutoResetEvent) void {
        self.event.set();
    }
};