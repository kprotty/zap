const builtin = @import("builtin");

pub const arch_type = builtin.arch;

pub const is_x86 = switch (arch_type) {
    .i386, .x86_64 => true,
    else => false,
};

pub const is_arm = switch (arch_type) {
    .arm, .aarch64 => true,
    else => false,
};

pub const atomic = @import("./atomic.zig");
pub const Lock = @import("./lock.zig").Lock;

pub const Waker = struct {
    wakeFn: fn(*Waker) void,

    pub fn wake(self: *Waker) void {
        return (self.wakeFn)(self);
    }
};

pub fn SpinWait(comptime Event: type) type {
    return struct {
        spin: usize = 0,

        const Self = @This();

        pub fn reset(self: *Self) void {
            self.* = Self{};
        }

        pub fn trySpin(self: *Self) bool {
            if (Event.yield(self.spin)) {
                self.spin +%= 1;
                return true;
            }

            return false;
        }

        pub fn yield(self: *Self) void {
            _ = Event.yield(null);
        }
    };
}

pub const SpinEvent = struct {
    is_notified: atomic.Atomic(bool) = atomic.Atomic(bool).init(false),

    pub fn wait(self: *SpinEvent, deadline: ?Timestamp) bool {
        while (!self.is_notified.load(.acquire))
            atomic.spinLoopHint();

        self.is_notified.set(false);
        return true;
    }

    pub fn notify(self: *SpinEvent) void {
        self.is_notified.store(true, .release);
    }

    pub fn yield(iteration: ?usize) bool {
        atomic.spinLoopHint();
        return false;
    }

    pub fn nanotime() u64 {
        return 0;
    }
};