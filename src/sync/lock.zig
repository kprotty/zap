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

pub fn Lock(comptime Signal: type) type {
    return struct {
        const Self = @This();

        const UNLOCKED = 0;
        const LOCKED = 1 << 0;
        const WAKING = 1 << 1;
        const WAITING = ~@as(usize, (1 << 2) - 1);

        const Waiter = struct {
            prev: ?*Waiter align((~WAITING) + 1),
            next: ?*Waiter,
            tail: ?*Waiter,
            signal: Signal,
        };

        state: usize = UNLOCKED,

        pub fn acquire(self: *Self) void {
            const acquired = switch (std.builtin.arch) {
                // on x86, unlike cmpxchg, bts doesnt require a register setup for the value
                // which results in a slightly smaller hit on the i-cache. 
                .i386, .x86_64 => asm volatile(
                    "lock btsl $0, %[ptr]"
                    : [ret] "={@ccc}" (-> u8),
                    : [ptr] "*m" (&self.state)
                    : "cc", "memory"
                ) == 0,
                else => @cmpxchgWeak(
                    usize,
                    &self.state,
                    UNLOCKED,
                    LOCKED,
                    .Acquire,
                    .Monotonic,
                ) == null,
            };

            if (!acquired)
                self.acquireSlow();
        }

        fn acquireSlow(self: *Self) void {
            @setCold(true);

            var spin: usize = 0;
            var is_waking = false;
            var has_signal = false;
            var waiter: Waiter = undefined;
            var state = @atomicLoad(usize, &self.state, .Monotonic);

            while (true) {
                var new_state = state;
                const head = @intToPtr(?*Waiter, state & WAITING);

                if (state & LOCKED == 0) {
                    new_state |= LOCKED;

                } else if (head == null and Signal.canYield(spin)) {
                    Signal.yield(spin);
                    spin +%= 1;
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                    continue;

                } else {
                    waiter.prev = null;
                    waiter.next = head;
                    waiter.tail = if (head == null) &waiter else null;
                    new_state = (new_state & ~WAITING) | @ptrToInt(&waiter);

                    if (!has_signal) {
                        has_signal = true;
                        waiter.signal.init();
                    }
                }

                if (is_waking)
                    new_state &= ~@as(usize, WAKING);

                if (@cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    new_state,
                    .AcqRel,
                    .Monotonic,
                )) |updated_state| {
                    state = updated_state;
                    continue;
                }

                if (state & LOCKED == 0) {
                    if (has_signal)
                        waiter.signal.deinit();
                    return;
                }

                waiter.signal.wait();

                spin = 0;
                is_waking = true;
                state = @atomicLoad(usize, &self.state, .Monotonic);
            }
        }

        pub fn release(self: *Self) void {
            return self.releaseFast(false);
        }

        pub fn releaseHandoff(self: *Self) void {
            return self.releaseFast(true);
        }

        fn releaseFast(self: *Self, handoff: bool) void {
            const state = @atomicRmw(usize, &self.state, .Sub, LOCKED, .Release);

            if ((state & WAITING != 0) and (state & WAKING == 0))
                self.releaseSlow(handoff);
        }

        fn releaseSlow(self: *Self, handoff: bool) void {
            @setCold(true);

            var state = @atomicLoad(usize, &self.state, .Monotonic);
            while (true) {
                if ((state & WAITING == 0) or (state & (LOCKED | WAKING) != 0))
                    return;
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    state | WAKING,
                    .Acquire,
                    .Monotonic,
                ) orelse break;
            }

            while (true) {
                const head = @intToPtr(*Waiter, state & WAITING);
                const tail = head.tail orelse blk: {
                    var current = head;
                    while (true) {
                        const next = current.next.?;
                        next.prev = current;
                        current = next;
                        if (current.tail) |tail| {
                            head.tail = tail;
                            break :blk tail;
                        }
                    }
                };

                if (state & LOCKED != 0) {
                    state = @cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        state & ~@as(usize, WAKING),
                        .AcqRel,
                        .Acquire,
                    ) orelse return;
                    continue;
                }

                if (tail.prev) |new_tail| {
                    head.tail = new_tail;
                    @fence(.Release);

                } else if (@cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    state & WAKING,
                    .AcqRel,
                    .Acquire,
                )) |updated_state| {
                    state = updated_state;
                    continue;
                }

                if (handoff) {
                    tail.signal.notifyHandoff();
                } else {
                    tail.signal.notify();
                }

                return;
            }
        }
    };
}