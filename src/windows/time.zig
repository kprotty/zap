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
const isWindowsVersionOrHigher = windows.isWindowsVersionOrHigher;

pub const Frequency = u64;

pub fn frequency() Frequency {
    return windows.QueryPerformanceFrequency();
}

pub const is_actually_monotonic = false;

pub fn now(frequency: Frequency) u64 {
    const ticks = windows.QueryPerformanceCounter();
    const scaled = ticks * std.time.ns_per_s;
    return @divFloor(scaled, frequency);
}

pub const Lock = 
    if (isWindowsVersionOrHigher(.vista))
        struct {
            srwlock: windows.SRWLOCK = windows.SRWLOCK_INIT,

            pub fn acquire(self: *Lock) void {
                windows.AcquireSRWLockExclusive(&self.srwlock);
            }

            pub fn release(self: *Lock) void {
                windows.ReleaseSRWLockExclusive(&self.srwlock);
            }
        }
    else
        struct {
            state: usize = UNLOCKED,

            const UNLOCKED = 0;
            const LOCKED = 1;
            const WAKING = 2;
            const WAITING = 4;
            
            pub fn acquire(self: *Lock) void {
                const acquired = switch (std.builtin.arch) {
                    .i386, .x86_64 => asm volatile(
                        "lock btsl $0, %[ptr]"
                        : [ret] "={@ccc}" (-> u8),
                        : [ptr] "*m" (&self.key)
                        : "cc", "memory"
                    ) == 0,
                    else => @cmpxchgWeak(
                        u8,
                        @ptrCast(*u8, &self.state),
                        UNLOCKED,
                        LOCKED,
                        .Acquire,
                        .Monotonic,
                    ) == null,
                };

                if (!acquired)
                    self.acquireSlow();
            }

            fn acquireSlow(self: *Lock) void {
                @setCold(true);

                var spin: u3 = 0;
                var is_waking = false;
                var state = @atomicLoad(usize, &self.state, .Monotonic);

                while (true) {
                    var new_state = state;
                    if (is_waking)
                        new_state &= ~@as(usize, WAKING);

                    if (state & LOCKED == 0) {
                        new_state |= LOCKED;
                        if (is_waking)
                            new_state -= WAITING;

                    } else if ((state < WAITING) && (spin <= 3)) {
                        @import("./thread.zig").Thread.yield();
                        spin += 1;
                        state = @atomicLoad(usize, &self.state, .Monotonic);
                        continue;

                    } else if (!is_waking) {
                        new_state += WAITING;
                    }

                    if (@cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        new_state,
                        .Acquire,
                        .Monotonic,
                    )) |updated_state| {
                        state = updated_state;
                        continue;
                    }

                    if (state & LOCKED == 0)
                        return;

                    const key = @ptrCast(*const c_void, &self.state);
                    const status = windows.NtWaitForKeyedEvent(null, key, windows.FALSE, null);
                    std.debug.assert(status == .SUCCESS);

                    spin = 0;
                    is_waking = true;
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                }
            }

            pub fn release(self: *Lock) void {
                @atomicStore(u8, @ptrCast(*u8, &self.state), UNLOCKED, .Release);

                const state = @atomicLoad(usize, &self.state, .Monotonic);
                if ((state >= WAITING) && (state & (LOCKED | WAKING) == 0))
                    self.releaseSlow();
            }

            fn releaseSlow(self: *Lock) void {
                @setCold(true);

                switch (std.builtin.arch) {
                    .i386, .x86_64 => {
                        const is_waking = asm volatile(
                            "lock btsl $0, %[ptr]"
                            : [ret] "={@ccc}" (-> u8),
                            : [ptr] "*m" (&self.key)
                            : "cc", "memory"
                        ) == 0;
                        if (!is_waking)
                            return;
                    },
                    else => {
                        var state = @atomicLoad(usize, &self.state, .Monotonic);
                        while (true) {
                            if ((state < WAITING) or (state & (LOCKED | WAKING) == 0))
                                return;
                            state = @cmpxchgWeak(
                                usize,
                                &self.state,
                                state,
                                state | WAKING,
                                .Monotonic,
                                .Monotonic,
                            ) orelse break;
                        }
                    },
                }
                
                const key = @ptrCast(*const c_void, &self.state);
                const status = windows.NtReleaseKeyedEvent(null, key, windows.FALSE, null);
                std.debug.assert(status == .SUCCESS);
            }
        }
    ;

