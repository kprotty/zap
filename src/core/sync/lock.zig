// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const sync = @import("./sync.zig");

const Waker = sync.core.Waker;
const SuspendContext = sync.core.SuspendContext;

pub const Lock = struct {
    state: usize = UNLOCKED,

    const UNLOCKED = 0;
    const LOCKED = 1;
    const WAKING = 1 << 8;
    const WAITING = ~@as(usize, (1 << 9) - 1);

    const Waiter = struct {
        prev: ?*Waiter align(~WAITING + 1),
        next: ?*Waiter,
        tail: ?*Waiter,
        waker: *Waker,
    };

    pub fn tryAcquire(self: *Lock) bool {
        return @atomicRmw(
            u8,
            @ptrCast(*u8, &self.state),
            .Xchg,
            LOCKED,
            .Acquire,
        ) == UNLOCKED;
    }

    pub fn acquire(self: *Lock, comptime Continuation: type) void {
        if (!self.tryAcquire()) {
            self.acquireSlow(Continuation);
        }
    }

    fn acquireSlow(this: *Lock, comptime Continuation: type) void {
        @setCold(true);

        const Future = struct {
            lock: *Lock,
            state: State = .locking,
            waiter: Waiter = undefined,
            continuation: Continuation = Continuation{},
            waker: Waker = .{ .wakeFn = wake },
            suspend_context: SuspendContext = .{ .suspendFn = @"suspend?" },

            const Self = @This();
            const State = enum {
                locking,
                waiting,
                acquired,
            };

            fn wake(waker: *Waker) void {
                const self = @fieldParentPtr(Self, "waker", waker);
                self.continuation.@"resume"();
            }

            fn @"suspend?"(suspend_context: *SuspendContext) bool {
                const self = @fieldParentPtr(Self, "suspend_context", suspend_context);
                const lock = self.lock;

                var spin: usize = 0;
                var state = switch (self.state) {
                    .locking => @atomicLoad(usize, &lock.state, .Monotonic),
                    .waiting => @atomicRmw(usize, &lock.state, .Sub, WAKING, .Monotonic) - WAKING,
                    .acquired => unreachable, // future polled after completion
                };

                while (true) {
                    if (state & LOCKED == 0) {
                        if (lock.tryAcquire()) {
                            self.state = .acquired;
                            return false;
                        }
                        _ = Continuation.yield(null);
                        state = @atomicLoad(usize, &lock.state, .Monotonic);
                        continue;
                    }

                    const head = @intToPtr(?*Waiter, state & WAITING);
                    if (head == null and Continuation.yield(spin)) {
                        spin +%= 1;
                        state = @atomicLoad(usize, &lock.state, .Monotonic);
                        continue;
                    }

                    self.state = .waiting;
                    self.waiter.waker = &self.waker;
                    self.waiter.prev = null;
                    self.waiter.next = head;
                    self.waiter.tail = if (head == null) &self.waiter else null;

                    state = @cmpxchgWeak(
                        usize,
                        &lock.state,
                        state,
                        (state & ~WAITING) | @ptrToInt(&self.waiter),
                        .Release,
                        .Monotonic,
                    ) orelse return true;
                }
            }
        };

        var future = Future{ .lock = this };
        while (future.state != .acquired) {
            future.continuation.@"suspend"(null, &future.suspend_context);
        }
    }

    pub fn release(self: *Lock) void {
        @atomicStore(
            u8,
            @ptrCast(*u8, &self.state),
            UNLOCKED,
            .Release,
        );

        const state = @atomicLoad(usize, &self.state, .Monotonic);
        if ((state & WAITING != 0) and (state & (LOCKED | WAKING) == 0)) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock) void {
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

        state |= WAKING;
        dequeue: while (true) {
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
                    .Release,
                    .Acquire,
                ) orelse return;
                continue;
            }

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                @fence(.Release);
            } else {
                while (true) {
                    state = @cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        (state & LOCKED) | WAKING,
                        .Monotonic,
                        .Monotonic,
                    ) orelse break;
                    if (state & WAITING != 0) {
                        @fence(.Acquire);
                        continue :dequeue;
                    }
                }
            }

            tail.waker.wake();
            return;
        }
    }
};