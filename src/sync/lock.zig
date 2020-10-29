const std = @import("std");
const zap = @import("../zap.zig");

pub fn Lock(comptime Signal: type) type {
    return extern struct {
        state: usize = UNLOCKED,

        const UNLOCKED = 0;
        const LOCKED = 1;
        const WAKING = 2;
        const WAITING = ~@as(usize, LOCKED | WAKING);

        const Self = @This();
        const Waiter = struct {
            aligned: void align(~WAITING + 1),
            prev: ?*Waiter,
            next: ?*Waiter,
            tail: ?*Waiter,
            signal: Signal,
        };

        const spinLoopHint = zap.sync.core.spinLoopHint;
        const isx86 = switch (std.builtin.arch) {
            .i386, .x86_64 => true,
            else => false,
        };

        pub fn tryAcquire(self: *Self) bool {
            if (isx86) {
                return asm volatile(
                    "lock btsw $0, %[ptr]"
                    : [ret] "={@ccc}" (-> u8),
                    : [ptr] "*m" (&self.state)
                    : "cc", "memory"
                ) == 0;
            }

            var state = @atomicLoad(usize, &self.state, .Monotonic);
            while (true) {
                if (state & LOCKED != 0)
                    return false;
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    state | LOCKED,
                    .Acquire,
                    .Monotonic,
                ) orelse return true;
            }
        }

        pub fn acquire(self: *Self) void {
            const acquired = 
                if (isx86) self.tryAcquire()
                else @cmpxchgWeak(
                    usize,
                    &self.state,
                    UNLOCKED,
                    LOCKED,
                    .Acquire,
                    .Monotonic,
                ) == null;

            if (!acquired) {
                self.acquireSlow();
            }
        }

        fn acquireSlow(self: *Self) void {
            @setCold(true);

            var waiter: Waiter = undefined;
            var has_signal = false;
            defer if (has_signal)
                waiter.signal.deinit();

            var spin: std.math.Log2Int(usize) = 0;
            var state = @atomicLoad(usize, &self.state, .Monotonic);
            while (true) {

                if (state & LOCKED == 0) {
                    state = blk: {
                        if (isx86) {
                            if (self.tryAcquire())
                                return;
                            spinLoopHint();
                            break :blk @atomicLoad(usize, &self.state, .Monotonic);
                        } else {
                            break :blk @cmpxchgWeak(
                                usize,
                                &self.state,
                                state,
                                state | LOCKED,
                                .Acquire,
                                .Monotonic,
                            ) orelse return;
                        }
                    };
                    continue;
                }

                const head = @intToPtr(?*Waiter, state & WAITING);
                if (head == null and spin <= 3) {
                    spin +%= 1;
                    var iters = @as(usize, 1) << spin;
                    while (iters > 0) : (iters -= 1)
                        spinLoopHint();
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                    continue;
                }

                if (!has_signal) {
                    has_signal = true;
                    waiter.signal.init();
                }

                waiter.prev = null;
                waiter.next = head;
                waiter.tail = if (head == null) &waiter else null;

                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    (state & ~WAITING) | @ptrToInt(&waiter),
                    .Release,
                    .Monotonic,
                ) orelse blk: {
                    spin = 0;
                    waiter.signal.wait();
                    break :blk @atomicLoad(usize, &self.state, .Monotonic);
                };
            }
        }

        pub fn release(self: *Self) void {
            const state = @atomicRmw(usize, &self.state, .Sub, LOCKED, .Release);
            if (state & WAITING != 0) {
                self.releaseSlow();
            }
        }

        fn releaseSlow(self: *Self) void {
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
                ) orelse {
                    state |= WAKING;
                    break;
                };
            }

            dequeue: while (true) {
                const head = @intToPtr(*Waiter, state & WAITING);
                const tail = head.tail orelse blk: {
                    var current = head;
                    while (true) {
                        const next = current.next orelse unreachable;
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
                    _ = @atomicRmw(usize, &self.state, .And, ~@as(usize, WAKING), .Release);
                } else if (@cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    UNLOCKED,
                    .Acquire,
                    .Acquire,
                )) |updated| {
                    state = updated;
                    continue;
                }

                tail.signal.notify();
                return;
            }
        }
    };
}