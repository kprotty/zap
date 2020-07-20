const std = @import("std");
const assert = std.debug.assert;
const system = @import("../system.zig");

pub fn Lock(comptime AutoResetEvent: type) type {
    return struct {
        const Self = @This();

        const Waiter = struct {
            prev: ?*Waiter,
            next: ?*Waiter,
            tail: ?*Waiter,
            event: AutoResetEvent,
        };
        
        const UNLOCKED: usize = 0 << 0;
        const MUTEX_LOCK: usize = 1 << 0;
        const QUEUE_LOCK: usize = 1 << 1;
        const QUEUE_MASK: usize = ~(MUTEX_LOCK | QUEUE_LOCK);

        state: usize,

        pub fn init() Self {
            return Self{ .state = UNLOCKED };
        }

        pub fn deinit(self: *Self) void {
            const state = @atomicLoad(usize, &self.state, .Monotonic);
            assert(state & QUEUE_MASK == 0);
        }

        pub fn acquire(self: *Self) void {
            if (@cmpxchgWeak(
                usize,
                &self.state,
                UNLOCKED,
                MUTEX_LOCK,
                .Acquire,
                .Monotonic,
            )) |state| {
                self.acquireSlow(state);
            }
        }

        fn acquireSlow(self: *Self, new_state: usize) void {
            comptime assert(@alignOf(Waiter) >= (~QUEUE_MASK) + 1);
            @setCold(true);

            var spin: u4 = 0;
            var state = new_state;
            var has_event = false;
            var waiter: Waiter = undefined;
            
            while (true) {
                if (state & MUTEX_LOCK == 0) {
                    state = @cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        state | MUTEX_LOCK,
                        .Acquire,
                        .Monotonic,
                    ) orelse break;
                    continue;
                }

                const head = @intToPtr(?*Waiter, state & QUEUE_MASK);
                if (head == null and spin <= 3) {
                    system.spinLoopHint(@as(usize, 1) << spin);
                    spin += 1;
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                    continue;
                }

                waiter.prev = null;
                waiter.next = head;
                waiter.tail = if (head == null) &waiter else null;
                if (!has_event) {
                    waiter.event.init();
                    has_event = true;
                }

                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    (state & ~QUEUE_MASK) | @ptrToInt(&waiter),
                    .Release,
                    .Monotonic,
                ) orelse blk: {
                    waiter.event.wait();
                    spin = 0;
                    break :blk @atomicLoad(usize, &self.state, .Monotonic);
                };
            }

            if (has_event)
                waiter.event.deinit();
        }

        pub fn release(self: *Self) void {
            const state = @atomicRmw(usize, &self.state, .Sub, MUTEX_LOCK, .Release);
            if ((state & QUEUE_LOCK == 0) and (state & QUEUE_MASK != 0))
                self.releaseSlow(state);
        }

        fn releaseSlow(self: *Self, new_state: usize) void {
            @setCold(true);

            var state = new_state - MUTEX_LOCK;
            while (true) {
                if ((state & QUEUE_LOCK != 0) or (state & QUEUE_MASK == 0))
                    return;
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    state | QUEUE_LOCK,
                    .Acquire,
                    .Monotonic,
                ) orelse break;
            }

            outer: while (true) {
                const head = @intToPtr(*Waiter, state & QUEUE_MASK);

                const tail = head.tail orelse blk: {
                    var current = head;
                    while (true) {
                        const next = current.next.?;
                        next.prev = current;
                        current = next;
                        if (current.tail) |t| {
                            head.tail = t;
                            break :blk t;
                        }
                    }
                };

                if (state & MUTEX_LOCK != 0) {
                    state = @cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        state & ~QUEUE_LOCK,
                        .Release,
                        .Acquire,
                    ) orelse return;
                    continue;
                }

                if (tail.prev) |new_tail| {
                    head.tail = new_tail;
                    _ = @atomicRmw(usize, &self.state, .And, ~QUEUE_LOCK, .Release);
                } else {
                    while (true) {
                        state = @cmpxchgWeak(
                            usize,
                            &self.state,
                            state,
                            state & MUTEX_LOCK,
                            .Release,
                            .Acquire,
                        ) orelse break;
                        if (state & QUEUE_MASK != 0)
                            continue :outer;
                    }
                }

                tail.event.notify();
                return;
            }
        }
    };
}