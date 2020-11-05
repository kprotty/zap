const std = @import("std");
const core = @import("../core.zig");

const is_x86 = core.is_x86;
const atomic = core.sync.atomic;
const Waker = core.sync.Waker;
const Condition = core.sync.Condition;

pub const Lock = extern struct {
    state: atomic.Atomic(usize) = atomic.Atomic(usize).init(UNLOCKED),

    const UNLOCKED = 0;
    const LOCKED = 1;
    const WAKING = 2;
    const WAITING = ~@as(usize, LOCKED | WAKING);

    const Waiter = struct {
        prev: ?*Waiter align(~WAITING + 1) = undefined,
        next: ?*Waiter = undefined,
        tail: ?*Waiter = undefined,
        waker: Waker = undefined,
    };

    pub fn tryAcquire(self: *Lock) bool {
        if (is_x86) {
            return asm volatile(
                "lock btsw $0, %[ptr]"
                : [ret] "={@ccc}" (-> u8),
                : [ptr] "*m" (&self.state)
                : "cc", "memory"
            ) == 0;
        }

        var state = self.state.load(.relaxed);
        while (true) {
            if (state & LOCKED != 0)
                return false;
            state = self.state.tryCompareAndSwap(
                state,
                state | LOCKED,
                .acquire,
                .relaxed,
            ) orelse return true;
        }
    }

    pub fn acquire(self: *Lock, comptime Futex: type) void {
        const acquired = blk: {
            if (is_x86)
                break :blk self.tryAcquire();
            break :blk self.state.tryCompareAndSwap(
                UNLOCKED,
                LOCKED,
                .acquire,
                .relaxed,
            ) == null;
        };

        if (!acquired) {
            self.acquireSlow(Futex);
        }
    }

    fn acquireSlow(self: *Lock, comptime Futex: type) void {
        @setCold(true);

        const Future = struct {
            lock: *Lock,
            state: State = .locking,
            futex: Futex = Futex{},
            condition: Condition = Condition{ .isMetFn = poll },
            waiter: Waiter = Waiter{ .waker = Waker{ .wakeFn = wake } },

            const Self = @This();
            const State = enum {
                locking,
                waiting,
                acquired,
            };
            
            fn wake(waker: *Waker) void {
                const waiter = @fieldParentPtr(Waiter, "waker", waker);
                const future = @fieldParentPtr(Self, "waiter", waiter);
                future.futex.wake();
            }

            fn poll(condition: *Condition) bool {
                const future = @fieldParentPtr(Self, "condition", condition);
                const lock = switch (future.state) {
                    .locking, .waiting => future.lock,
                    .acquired => @panic("Lock.acquire future polled after completion"),
                };

                var spin: std.math.Log2Int(usize) = 0;
                var state = switch (future.state) {
                    .locking => lock.state.load(.relaxed),
                    .waiting => lock.state.fetchSub(WAKING, .relaxed) - WAKING,
                    .acquired => unreachable,
                };

                while (true) {
                    if (state & LOCKED == 0) {
                        if (is_x86) {
                            if (lock.tryAcquire())
                                break;
                            atomic.spinLoopHint();
                            state = lock.state.load(.relaxed);
                            continue;
                        }
                        
                        state = lock.state.tryCompareAndSwap(
                            state,
                            state | LOCKED,
                            .acquire,
                            .relaxed,
                        ) orelse break;
                        continue;
                    }

                    const head = @intToPtr(?*Waiter, state & WAITING);
                    if (head == null and spin <= 3) {
                        spin +%= 1;
                        var iters = @as(usize, 1) << spin;
                        while (iters > 0) : (iters -= 1)
                            atomic.spinLoopHint();
                        state = lock.state.load(.relaxed);
                        continue;
                    }

                    future.state = .waiting;
                    future.waiter.prev = null;
                    future.waiter.next = head;
                    future.waiter.tail = if (head == null) &future.waiter else null;

                    state = lock.state.tryCompareAndSwap(
                        state,
                        (state & ~WAITING) | @ptrToInt(&future.waiter),
                        .release,
                        .relaxed,
                    ) orelse return false;
                }

                future.state = .acquired;
                return true;
            }
        };

        var future = Future{ .lock = self };
        while (future.state != .acquired) {
            const timed_out = !future.futex.wait(null, &future.condition);
            if (timed_out)
                @panic("Lock.acquire future timed out without a deadline");
        }
    }

    pub fn release(self: *Lock) void {
        const state = self.state.fetchSub(LOCKED, .release);
        if ((state & WAITING != 0) and (state & WAKING == 0)) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        var state = self.state.load(.relaxed);
        while (true) {
            if ((state & WAITING == 0) or (state & (LOCKED | WAKING) != 0))
                return;
            state = self.state.tryCompareAndSwap(
                state,
                state | WAKING,
                .consume,
                .relaxed,
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
                state = self.state.tryCompareAndSwap(
                    state,
                    state & ~@as(usize, WAKING),
                    .release,
                    .consume,
                ) orelse return;
                continue;
            }

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                // _ = self.state.fetchAnd(~@as(usize, WAKING), .release);
            } else if (self.state.tryCompareAndSwap(
                state,
                WAKING,
                .consume,
                .consume,
            )) |updated| {
                state = updated;
                continue;
            }

            tail.waker.wake();
            return;
        }
    }
};