const std = @import("std");

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
        event: std.AutoResetEvent,
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

    pub fn acquire(self: *Lock) void {
        if (!self.tryAcquire()) {
            self.acquireSlow();
        }
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        var waiter: Waiter = undefined;
        var spin: std.math.Log2Int(usize) = 0;
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            if (state & LOCKED == 0) {
                if (self.tryAcquire())
                    return;
                std.os.sched_yield() catch unreachable;
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;
            }

            const head = @intToPtr(?*Waiter, state & WAITING);
            if (head == null and spin < 10) {
                spin +%= 1;
                if (spin <= 3) {
                    std.SpinLock.loopHint(@as(usize, 1) << spin);
                } else {
                    std.os.sched_yield() catch unreachable;
                }
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;
            }

            waiter.event = std.AutoResetEvent{};
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
                waiter.event.wait();
                break :blk (@atomicRmw(usize, &self.state, .Sub, WAKING, .Monotonic) - WAKING);
            };
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

            tail.event.set();
            return;
        }
    }
};