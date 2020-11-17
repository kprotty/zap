const core = @import("./core.zig");

const Waker = core.Waker;
const SpinWait = core.SpinWait;
const Atomic = core.atomic.Atomic;
const fence = core.atomic.fence;

pub const Lock = struct {
    state: Atomic(usize) = Atomic(usize).init(UNLOCKED),

    const UNLOCKED = 0;
    const LOCKED = 1;
    const WAKING = 1 << 8;
    const WAITING = ~@as(usize, (1 << 9) - 1);

    const Waiter = struct {
        prev: ?*Waiter align(~WAITING + 1) = undefined,
        next: ?*Waiter = undefined,
        tail: ?*Waiter = undefined,
        waker: Waker,
    };

    pub fn tryAcquire(self: *Lock) bool {
        if (core.is_x86) {
            return asm volatile(
                "lock btsl $0, %[ptr]"
                : [ret] "={@ccc}" (-> u8),
                : [ptr] "*m" (&self.state)
                : "cc", "memory"
            ) == 0;
        }
        
        const byte_state = @ptrCast(*Atomic(u8), &self.state);
        return byte_state.swap(LOCKED, .acquire) == UNLOCKED;
    }

    pub fn acquire(self: *Lock, comptime Event: type) void {
        if (!self.tryAcquire())) {
            self.acquireSlow(Event);
        }
    }

    fn acquireSlow(self: *Lock, comptime Event: type) void {
        @setCold(true);

        const EventWaiter = struct {
            waiter: Waiter = Waiter{ .waker = Waker{ .wakeFn = wake } },
            event: Event = Event{},

            fn wake(waker: *Waker) void {
                const waiter = @fieldParentPtr(Waiter, "waker", waker);
                const self = @fieldParentPtr(@This(), "waiter", waiter);
                self.event.notify();
            }
        };

        var event_waiter = EventWaiter{};
        var spin_wait = SpinWait(Event){};
        var state = self.state.load(.relaxed);

        while (true) {
            if (state & LOCKED == 0) {
                if (self.tryAcquire())
                    return;
                spin_wait.yield();
                state = self.state.load(.relaxed);
                continue;
            }

            const head = @intToPtr(?*Waiter, state & WAITING);
            if (head == null and spin_wait.trySpin()) {
                state = self.state.load(.relaxed);
                continue;
            }

            const waiter = &event_waiter.waiter;
            waiter.prev = null;
            waiter.next = head;
            waiter.tail = if (head == null) waiter else null;

            if (self.state.tryCompareAndSwap(
                state,
                (state & ~WAITING) | @ptrToInt(waiter),
                .release,
                .relaxed,
            )) |updated| {
                state = updated;
                continue;
            }

            spin_wait.reset();
            event_waiter.event.wait();
            state = self.state.load(.relaxed);
        }
    }

    pub fn release(self: *Lock) void {
        const byte_state = @ptrCast(*Atomic(u8), &self.state);
        byte_state.store(UNLOCKED, .release);

        const state = self.state.load(.relaxed);
        if (state & WAITING != 0) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock, comptime Event: type) void {
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
                    .acquire,
                ) orelse return;
                continue;
            }

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                fence(.release);
            } else if (self.state.tryCompareAndSwap(
                state,
                WAKING,
                .release,
                .acquire,
            )) |updated| {
                state = updated;
                continue;
            }

            return (tail.wakeFn)(tail);
        }
    }
};