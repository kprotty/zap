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

pub fn WaitGroup(comptime Signal: type) type {
    return struct {
        const Self = @This();

        const Waiter = struct {
            const NOTIFIED = @intToPtr(*Waiter, @alignOf(Waiter));

            next: ?*Waiter,
            signal: Signal,
        };

        counter: isize = 0,
        waiters: ?*Waiter = null,

        pub fn done(self: *Self) void {
            self.add(-1);
        }

        pub fn add(self: *Self, workers: isize) void {
            if (workers == 0)
                return;

            var counter = @atomicLoad(isize, &self.counter, .Monotonic);
            var new_counter: isize = undefined;

            while (true) {
                new_counter = counter + workers;

                if (new_counter < 0)
                    std.debug.panic("negative WaitGroup counter", .{});
                if (counter == 0 and workers > 0 and @atomicLoad(?*Waiter, &self.waiters, .Monotonic) != null)
                    std.debug.panic("incrementing counter when already waiting", .{});

                counter = @cmpxchgWeak(
                    isize,
                    &self.counter,
                    counter,
                    new_counter,
                    .Monotonic,
                    .Monotonic,
                ) orelse break;
            }

            if (new_counter != 0)
                return;

            var waiters = @atomicRmw(?*Waiter, &self.waiters, .Xchg, Waiter.NOTIFIED, .AcqRel);
            if (waiters == Waiter.NOTIFIED)
                return;

            while (waiters) |pending_waiter| {
                const waiter = pending_waiter;
                waiters = waiter.next;
                waiter.signal.notify();
            }
        }

        pub fn wait(self: *Self) void {
            var waiter: Waiter = undefined;
            waiter.signal.init();
            defer waiter.signal.deinit();

            var waiters = @atomicLoad(?*Waiter, &self.waiters, .Acquire);
            while (true) {

                if (waiters == Waiter.NOTIFIED) {
                    if (@atomicLoad(isize, &self.counter, .Monotonic) == 0)
                        return;
                    waiter.next = null;
                } else {
                    waiter.next = waiters;
                }

                waiters = @cmpxchgWeak(
                    ?*Waiter,
                    &self.waiters,
                    waiters,
                    &waiter,
                    .Release,
                    .Acquire,
                ) orelse return waiter.signal.wait();
            }
        }
    };
}