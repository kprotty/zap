// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const windows = @import("./windows.zig");

pub const Event = extern struct {
    key: u32,

    pub fn init(self: *Event) void {}

    pub fn deinit(self: *Event) void {}

    pub fn reset(self: *Event) void {
        self.key = 0;
    }

    pub fn notify(self: *Event) void {
        // Release barrier to ensure waiting thread sees any changes we made.
        // If we're the first to modify, then the wait() caller will wake up on its own.
        if (self.tryModifyKey(.Release, .Monotonic))
            return;

        // The wait() thread modified the key first, wake it up by the notification.
        const ptr = @ptrCast(*const c_void, &self.key);
        const status = windows.NtReleaseKeyedEvent(null, ptr, windows.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    pub fn wait(self: *Event) void {
        // If we're not the first to modify the key, then we received a notification.
        // Acquire barrier on failure to make sure we return seeing any changes by the notify() thread. 
        // Acquire barrier on success as it needs to be at least equal to the failure ordering.
        if (!self.tryModifyKey(.Acquire, .Acquire))
            return;

        // wait for the notify() thread to wake us up.
        const ptr = @ptrCast(*const c_void, &self.key);
        const status = windows.NtWaitForKeyedEvent(null, ptr, windows.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    // Tries to atomically modify set the key value to 1.
    // Returns true if this thread was the first one to change it.
    inline fn tryModifyKey(
        self: *Event,
        comptime success: std.builtin.AtomicOrder,
        comptime failure: std.builtin.AtomicOrder,
    ) bool {
        return switch (std.builtin.arch) {
            // on x86, unlike cmpxchg, bts doesnt require a register setup for the value
            // which results in a slightly smaller hit on the i-cache. 
            .i386, .x86_64 => asm volatile(
                "lock btsl $0, %[ptr]"
                : [ret] "={@ccc}" (-> u8),
                : [ptr] "*m" (&self.key)
                : "cc", "memory"
            ) == 0,
            else => @cmpxchgStrong(
                u32,
                &self.key,
                @as(u32, 0),
                @as(u32, 1),
                success,
                failure,
            ) == null,
        };
    }
};