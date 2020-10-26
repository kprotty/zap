const std = @import("std");

pub const atomic = @import("./atomic.zig");

pub const Lock = @import("./sync/lock.zig").Lock;
pub const AutoResetEvent = @import("./sync/auto_reset_event.zig").AutoResetEvent;

pub const Waker = struct {
    wakeFn: fn(*Waker) void,

    pub fn wake(self: *Waker) void {
        return (self.wakeFn)(self);
    }
};

pub const Condition = struct {
    isMetFn: fn(*Condition) bool,

    pub fn isMet(self: *Condition) bool {
        return (self.isMetFn)(self);
    }
};

pub const SpinFutex = extern struct {
    notified: atomic.Atomic(bool) = undefined,

    pub fn wait(self: *SpinFutex, deadline: ?*Timestamp, condition: *Condition) bool {
        self.notified.set(false);

        if (!condition.isMet()) {
            while (!self.notified.load(.acquire))
                atomic.spinLoopHint();
        }

        return true;
    }

    pub fn wake(self: *SpinFutex) void {
        self.notified.store(true, .release);
    }

    pub fn yield(self: *SpinFutex, iteration: ?usize) bool {
        atomic.spinLoopHint();
        return true;
    }

    pub const Timestamp = void;

    pub fn timestamp(self: *SpinFutex, current: *Timestamp) void {
        current.* = undefined;
    }

    pub fn timeSince(self: *SpinFutex, t1: *Timestamp, t2: *Timestamp) u64 {
        return 0;
    }
};
