const std = @import("std");
const zap = @import("../zap.zig");
const core = zap.core;

pub const atomic = core.sync.atomic;

// pub const AsyncFutex = @import("./runtime/futex.zig").Futex;

pub const Futex = struct {
    event: Event = Event{},

    const Event = 
        if (core.is_windows) @import("./windows/event.zig").Event
        else if (core.is_posix) @import("./posix/event.zig").Event
        else if (core.is_linux) @import("./linux/event.zig").Event
        else @compileError("OS not supported for thread blocking/unblocking");

    pub fn wait(self: *Futex, deadline: ?*Timestamp, condition: *core.sync.Condition) bool {
        self.event.prepare();

        if (condition.isMet())
            return true;

        return self.event.wait(if (deadline) |d| d.* else null);
    }

    pub fn wake(self: *Futex) void {
        self.event.notify();
    }

    pub fn yield(self: *Futex, iteration: ?usize) bool {
        var iter = iteration orelse {
            Event.yield();
            return false;
        };

        if (iter <= 3) {
            while (iter != 0) : (iter -= 1)
                yieldCpu();
        } else {
            Event.yield();
        }

        return true;
    }

    pub const Timestamp = u64;

    pub fn timestamp(self: *Futex, current: *Timestamp) void {
        current.* = nanotime();
    }

    pub fn timeSince(self: *Futex, t1: *Timestamp, t2: *Timestamp) u64 {
        return t1.* - t2.*;
    }

    var last_lock = Lock{};
    var last_now = atomic.Atomic(u64).init(0);

    pub fn nanotime() u64 {
        const now = Event.nanotime();
        if (Event.is_monotonic)
            return now;

        if (std.meta.bitCount(usize) < 64) {
            last_lock.acquire();
            defer last_lock.release();
            
            const last = last_now.get();
            if (last > now)
                return last;
            
            last_now.set(now);
            return now;
        }

        var last = last_now.load(.relaxed);
        while (true) {
            if (last > now)
                return last;
            last = last_now.tryCompareAndSwap(
                last,
                now,
                .relaxed,
                .relaxed,
            ) orelse return now;
        }
    }
};

pub fn yieldCpu() void {
    atomic.spinLoopHint();
}

pub fn yieldThread() void {
    Futex.yield(null);
}

pub const Lock = extern struct {
    lock: core.sync.Lock = core.sync.Lock{},

    pub fn acquire(self: *Lock) void {
        self.lock.acquire(Futex);
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
        self.event.wait(Futex);
    }

    pub fn waitAsync(self: *AutoResetEvent) void {
        self.event.wait(AsyncFutex);
    }

    pub fn timedWait(self: *AutoResetEvent) error{TimedOut}!void {
        self.event.timedWait(Futex);
    }

    pub fn timedWaitAsync(self: *AutoResetEvent) error{TimedOut}!void {
        self.event.timedWait(AsyncFutex);
    }

    pub fn set(self: *AutoResetEvent) void {
        self.event.set();
    }
};