// Copyright 2020 kprotty
//
// Licensed under the Apache License, Version 2.0, <LICENSE-APACHE or
// http://apache.org/licenses/LICENSE-2.0> or the MIT license <LICENSE-MIT or
// http://opensource.org/licenses/MIT>, at your option. This file may not be
// copied, modified, or distributed except according to those terms.

pub const atomic = @import("./atomic.zig");
pub const parking_lot = @import("./parking_lot.zig");

pub const SpinParker = struct {
    notified: atomic.Atomic(bool),

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

pub fn SpinWait(comptime Parker: type) type {
    return struct {
        iter: ?usize = 0,

        const Self = @This();

        pub fn reset(self: *Self) void {
            self.* = Self{};
        }

        pub fn spin(self: *Self) bool {
            const iter = self.iter orelse return false;
            self.iter = if (Parker.yield(iter)) (iter +% 1) else null;
            return self.iter != null;
        }

        pub fn yield(self: *Self) void {
            if (!self.spin()) {
                _ = Parker.yield(null);
            }
        }
    };
}