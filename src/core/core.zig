const builtin = @import("builtin");

pub const sync = struct {
    pub const atomic = @import("./sync/atomic.zig");
    pub const parking_lot = @import("./sync/parking_lot.zig");

    pub const SpinParker = struct {
        notified: Atomic(bool),

        pub fn prepare(self: *SpinParker) void {
            self.notified.set(false);
        }

        pub fn park(self: *SpinParker, deadline: ?u64) bool {
            while (self.notified.load(.acquire) == false)
                atomic.spinLoopHint();
            return true;
        }

        pub fn unpark(self: *SpinParker) void {
            self.notified.store(true, .release);
        }
    };
};
