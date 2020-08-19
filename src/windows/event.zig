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
        if (self.tryModifyKey(.Release))
            return;

        const ptr = @ptrCast(*const c_void, &self.key);
        const status = windows.NtReleaseKeyedEvent(null, ptr, windows.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    pub fn wait(self: *Event) void {
        if (!self.tryModifyKey(.Acquire))
            return;

        const ptr = @ptrCast(*const c_void, &self.key);
        const status = windows.NtWaitForKeyedEvent(null, ptr, windows.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    fn tryModifyKey(self: *Event, comptime ordering: std.builtin.AtomicOrder) bool {
        return switch (std.builtin.arch) {
            .i386, .x86_64 => asm volatile(
                "lock incb %[ptr]"
                : [ret] "={@ccnz}" (-> u8),
                : [ptr] "*m" (x)
                : "cc", "memory"
            ) == 0,
            else => @atomicRmw(
                u32,
                &self.key,
                .Xchg,
                @as(u32, 1),
                ordering,
            ) == 0,
        };
    }
};