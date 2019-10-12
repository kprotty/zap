const std = @import("std");
const builtin = @import("builtin");

const zync = @import("../../zap.zig").zync;
const zuma = @import("../../zap.zig").zuma;

const expect = std.testing.expect;

pub usingnamespace switch (builtin.os) {
    .linux => if (builtin.link_libc) ImplPthread else ImplFutex,
    .windows => ImplFutex,
    else => ImplPthread,
};

pub const Spinlock = struct {
    value: zync.Atomic(bool),

    pub fn deinit(self: *@This()) void {}
    pub fn init(self: *@This()) void {
        self.value.set(false);
    }

    inline fn lock(self: *@This()) bool {
        return self.value.compareSwap(false, true, .Acquire, .Relaxed) == null;
    }

    pub fn tryAcquire(self: *@This(), timeout_ms: ?u32) bool {
        const timeout = timeout_ms orelse return self.value.comp

        var backoff: usize = 1;
        const now = zuma.Thread.now(.Monotonic);
        while (!self.lock()) {
            zync.yield(backoff);
            backoff += std.math.max(1, backoff / 2);

        };
    }

    pub fn acquire(self: *@This()) void {
        var backoff: usize = 1;
        while (!self.value.compareSwap(false, true, .Acquire, .Relaxed)) |_| {
            zync.yield(backoff);
            backoff += std.math.max(1, backoff / 2);
        };
    }

    pub fn release(self: *@This()) void {
        self.value.store(false, .Release);
    }
};

const ImplFutex = struct {
    pub const Mutex = struct {
        futex: zync.Futex,
        value: zync.Atomic(enum(u32) {
            Unlocked,
            Locked,
            Sleeping,
        }),

        pub fn init(self: *@This()) void {
            self.value.set(.Unlocked);
            self.futex.init();
        }

        pub fn deinit(self: *@This()) void {
            self.futex.deinit();
        }

        pub fn tryAcquire(self: *@This(), timeout_ms: ?u32) bool {
            return self.value.compareSwap(.Unlocked, .Locked, .Acquire, .Relaxed) == null;
        }

        pub fn acquire(self: *@This()) bool {

        }

        pub fn release(self: *@This()) void {

        }
    };
};

const ImplPthread = struct {

};
