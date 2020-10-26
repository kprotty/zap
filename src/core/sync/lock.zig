const std = @import("std");
const sync = @import("../sync.zig");

pub const Lock = extern struct {
    state: sync.atomic.Atomic(usize) = sync.atomic.Atomic(usize).init(UNLOCKED),

    const UNLOCKED = 0;
    const LOCKED = 1;
    const WAKING = 1 << 8;
    const WAITING = ~@as(usize, (1 << 9) - 1);

    const Waiter = struct {
        aligned: void align(~WAITING + 1) = undefined,
        prev: ?*Waiter = undefined,
        next: ?*Waiter = undefined,
        tail: ?*Waiter = undefined,
        waker: sync.Waker,
    };

    inline fn byteState(self: *Lock) *sync.atomic.Atomic(u8) {
        return @ptrCast(*sync.atomic.Atomic(u8), &self.state);
    }

    pub fn tryAcquire(self: *Lock) bool {
        return self.byteState().swap(LOCKED, .acquire) == UNLOCKED;
    }

    pub fn acquire(self: *Lock, comptime Futex: type) void {
        if (!self.tryAcquire()) {
            self.acquireSlow(Futex);
        }
    }

    fn acquireSlow(this: *Lock, comptime Futex: type) void {
        @setCold(true);

        const Future = struct {
            lock: *Lock,
            futex: Futex = Futex{},
            state: FutureState = .locking,
            waiter: Waiter = Waiter{ .waker = sync.Waker{ .wakeFn = wake } },
            condition: sync.Condition = sync.Condition{ .isMetFn = isConditionMet },

            const Self = @This();
            const FutureState = enum {
                locking,
                waiting,
                acquired,
            };

            fn wake(waker: *sync.Waker) void {
                const waiter = @fieldParentPtr(Waiter, "waker", waker);
                const self = @fieldParentPtr(Self, "waiter", waiter);
                self.futex.wake();
            }

            fn isConditionMet(condition: *sync.Condition) bool {
                const self = @fieldParentPtr(Self, "condition", condition);
                const lock = self.lock;

                var spin: usize = 0;
                var state = switch (self.state) {
                    .locking => lock.state.load(.relaxed),
                    .waiting => lock.state.fetchSub(WAKING, .relaxed) - WAKING,
                    .acquired => unreachable, // locking when already acquired
                };

                while (true) {
                    if (state & LOCKED == 0) {
                        if (lock.tryAcquire()) {
                            self.state = .acquired;
                            return true;
                        }
                        _ = self.futex.yield(null);
                        state = lock.state.load(.relaxed);
                        continue;
                    }

                    const head = @intToPtr(?*Waiter, state & WAITING);
                    if (head == null and self.futex.yield(spin)) {
                        spin +%= 1;
                        state = lock.state.load(.relaxed);
                        continue;
                    }

                    self.state = .waiting;
                    self.waiter.prev = null;
                    self.waiter.next = head;
                    self.waiter.tail = if (head == null) &self.waiter else null;

                    state = lock.state.tryCompareAndSwap(
                        state,
                        (state & ~WAITING) | @ptrToInt(&self.waiter),
                        .release,
                        .relaxed,
                    ) orelse return false;
                }                
            }
        };

        var future = Future{ .lock = this };
        while (future.state != .acquired) {
            if (!future.futex.wait(null, &future.condition))
                unreachable; // Futex impl. timed out when no deadline was provided
        }
    }

    pub fn release(self: *Lock) void {
        self.byteState().store(UNLOCKED, .release);

        const state = self.state.load(.relaxed);
        if ((state & WAITING != 0) and (state & (LOCKED | WAKING) == 0)) {
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
                .acquire,
                .relaxed,
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
                state = self.state.tryCompareAndSwap(
                    state,
                    state & ~@as(usize, WAKING),
                    .release,
                    .acquire,
                ) orelse return;
                continue;
            }

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                sync.atomic.fence(.release);
            } else {
                while (true) {
                    state = self.state.tryCompareAndSwap(
                        state,
                        (state & LOCKED) | WAKING,
                        .relaxed,
                        .relaxed,
                    ) orelse break;
                    if (state & WAITING != 0) {
                        sync.atomic.fence(.acquire);
                        continue :dequeue;
                    }
                }
            }

            tail.waker.wake();
            return;
        }
    }
};