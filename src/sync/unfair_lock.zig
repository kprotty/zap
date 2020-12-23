const builtin = @import("builtin");
const atomic = @import("./atomic.zig");

pub const Lock = struct {
    state: usize = UNLOCKED,

    const UNLOCKED = 0;
    const LOCKED = 1;
    const WAKING = 1 << 8;
    const WAITING = ~@as(usize, (1 << 9) - 1);

    const Waiter = struct {
        prev: ?*Waiter align(std.math.max(@alignOf(usize), ~WAITING + 1)),
        next: ?*Waiter,
        tail: ?*Waiter,
        wakeFn: fn(*Waiter) void,
    };

    fn Signal(comptime Event: type) type {
        return struct {
            event: usize,
            
            const Self = @This();
            const EVENT_EMPTY = 0;
            const EVENT_NOTIFIED = 1;

            fn reset(self: *Self) void {
                self.event = EVENT_EMPTY;
            }

            fn wait(self: *Self) void {
                var event: Event = undefined;
                event.init();
                defer event.deinit();

                const WaitCondition = struct {
                    signal_ptr: *Waiter,
                    event_ptr: *Event,

                    pub fn wait(this: @This()) bool {
                        return atomic.compareAndSwap(
                            &this.signal_ptr.event,
                            EVENT_EMPTY,
                            @ptrToInt(this.event_ptr),
                            .release,
                            .relaxed,
                        ) == null;
                    }
                };

                event.wait(null, WaitCondition{
                    .signal_ptr = self,
                    .event_ptr = &event,
                }) catch unreachable;
            }

            fn notify(self: *Self) void {
                if (atomic.compareAndSwap(
                    &self.event,
                    EVENT_EMPTY,
                    EVENT_NOTIFIED,
                    .consume,
                    .consume,
                )) |event_ptr| {
                    const event = @intToPtr(*Event, event_ptr);
                    event.notify();
                }
            }
        }
    }

    pub fn tryAcquire(self: *Lock) bool {
        switch (builtin.arch) {
            .i386, .x86_64 => {
                return atomic.bitSet(
                    &self.state,
                    @ctz(u3, LOCKED),
                    .acquire
                ) == UNLOCKED;
            },
            else => {
                return atomic.swap(
                    @ptrCast(*u8, self.state),
                    LOCKED,
                    .acquire,
                ) == UNLOCKED;
            },
        };
    }

    pub fn acquire(self: *Lock, comptime Event: type) void {
        if (!self.tryAcquire())
            self.acquireSlow(Event);
    }

    pub fn release(self: *Lock) void {
        atomic.store(@ptrCast(*u8, &self.state), UNLOCKED, .release);

        const state = atomic.load(&self.state, .relaxed);
        if (state & WAITING != 0)
            self.releaseSlow();
    }

    fn acquireSlow(self: *Lock, comptime Event: type) void {
        @setCold(true);

        var wait_signal: struct {
            waiter: Waiter,
            signal: Signal(Event),

            fn wake(waiter: *Waiter) void {
                const this = @fieldParentPtr(@This(), "waiter", waiter);
                this.signal.notify();
            }
        } = undefined;
        
        var spin_iter: usize = 0;
        var signal = &wait_signal.signal;
        var waiter = &wait_signal.waiter;
        var state = atomic.load(&self.state, .relaxed);

        while (true) {
            if (state & LOCKED == 0) {
                if (self.tryAcquire())
                    return;
                _ = Event.yield(null);
                state = atomic.load(&self.state, .relaxed);
                continue;
            }

            const head = @intToPtr(?*Waiter, state & WAITING);
            if (head == null and Event.yield(spin_iter)) {
                spin_iter +%= 1;
                state = atomic.load(&self.state, .relaxed);
                continue;
            }

            waiter.prev = null;
            waiter.next = head;
            waiter.tail = if (head == null) waiter else null;

            signal.reset();
            waiter.wakeFn = @TypeOf(wait_signal).wake;

            state = atomic.tryCompareAndSwap(
                &self.state,
                state,
                (state & ~WAITING) | @ptrToInt(&waiter),
                .release,
                .relaxed,
            ) orelse blk: {
                signal.wait();
                spin_iter = 0;
                break :blk atomic.load(&self.state, .relaxed);
            };
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        var state = atomic.load(&self.state, .relaxed);
        while (true) {
            if ((state & WAITING == 0) or (state & (LOCKED | WAKING) != 0))
                return;
            state = atomic.tryCompareAndSwap(
                &self.state,
                state,
                state | WAKING,
                .acquire,
                .relaxed,
            ) orelse break;
        }

        state |= WAKING;
        while (true) {
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
                state = atomic.tryCompareAndSwap(
                    &self.state,
                    state,
                    state & ~@as(usize, WAKING),
                    .release,
                    .acquire,
                ) orelse return;
                continue;
            }

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                _ = atomic.fetchAnd(&self.state, ~@as(usize, WAKING), .release);
            } else if (atomic.tryCompareAndSwap(
                &self.state,
                state,
                UNLOCKED,
                .release,
                .acquire,
            )) |updated| {
                state = updated;
                continue;
            }

            (tail.wakeFn)(tail);
            return;
        }
    }
};