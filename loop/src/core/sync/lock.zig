const std = @import("std");

pub fn Lock(comptime AutoResetEvent: type) type {
    return struct {
        const Self = @This();

        const UNLOCKED = 0;
        const LOCKED = 1 << 0;
        const WAKING = 1 << 8;
        const WAIT_ALIGN = 1 << 9;
        const WAITING = ~@as(usize, WAIT_ALIGN - 1);

        const Waiter = struct {
            prev: ?*Waiter,
            next: ?*Waiter,
            tail: ?*Waiter,
            event: AutoResetEvent,

            fn findTail(self: *Waiter) *Waiter {
                return self.tail orelse blk: {
                    var current = self;
                    while (true) {
                        const next = current.next.?;
                        next.prev = current;
                        current = next;
                        if (current.tail) |tail| {
                            self.tail = tail;
                            break :blk tail;
                        }
                    }
                };
            }
        };

        state: usize = UNLOCKED,

        pub fn init() Self {
            return Self{};
        }

        pub fn deinit(self: *Self) void {
            defer self.* = undefined;
            if (std.debug.runtime_safety) {
                const state = @atomicLoad(usize, &self.state, .Monotonic);
                if (state & WAITING != 0)
                    std.debug.panic("Lock.deinit() with existing waiters", .{});
            }
        }

        const isX86 = std.builtin.arch == .i386 or .arch == .x86_64;
        inline fn bitTestAndSet(self: *Self, comptime bit: u8) bool {
            comptime var bit_str = [1]u8{ '0' + bit };
            return asm volatile(
                "lock btsl $" ++ bit_str ++ ", %[state]\n" ++
                "setnc %[bit_is_now_set]"
                : [bit_is_now_set] "=r" (-> bool)
                : [state] "*m" (&self.state)
                : "cc", "memory"
            );
        }

        pub fn tryAcquire(self: *Self) bool {
            if (isX86)
                return self.bitTestAndSet(0);
            return @cmpxchgStrong(
                u8,
                @ptrCast(*u8, &self.state),
                UNLOCKED,
                LOCKED,
                .Acquire,
                .Monotonic,
            ) == null;
        }

        pub fn acquire(self: *Self) void {
            if (!self.tryAcquire())
                self.acquireSlow();
        }

        fn acquireSlow(self: *Self) void {
            @setCold(true);

            var has_event = false;
            var is_waking = false;
            var spin_iter: usize = 0;
            var waiter align(WAIT_ALIGN) = @as(Waiter, undefined);
            var state = @atomicLoad(usize, &self.state, .Acquire);

            while (true) {
                var new_state = state;
                const head = @intToPtr(?*Waiter, state & WAITING);
                
                if (state & LOCKED == 0) {
                    new_state |= LOCKED;
                    if (is_waking) {
                        new_state &= ~@as(usize, WAKING);
                        @fence(.Acquire);
                        if (head) |waiter_head| {
                            if (waiter_head == &waiter) {
                                new_state &= ~WAITING;
                            } else {
                                const tail = waiter_head.findTail();
                                waiter_head.tail = waiter.prev;
                            }
                        }
                    }

                } else if (is_waking) {
                    new_state &= ~@as(usize, WAKING);
                    @fence(.Acquire);
                    if (head) |waiter_head| {
                        const tail = waiter_head.findTail();
                        waiter_head.tail = &waiter;
                    }

                } else {
                    if (AutoResetEvent.yield(head != null, spin_iter)) {
                        spin_iter +%= 1;
                        state = @atomicLoad(usize, &self.state, .Monotonic);
                        continue;
                    }

                    waiter.prev = null;
                    waiter.next = head;
                    waiter.tail = if (head == null) &waiter else null;
                    new_state = (new_state & ~WAITING) | @ptrToInt(&waiter);
                    if (!has_event) {
                        has_event = true;
                        waiter.event.init();
                    }
                }

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
                    if (has_event)
                        waiter.event.deinit();
                    return;
                }

                waiter.event.wait();
                is_waking = true;
                state = @atomicLoad(usize, &self.state, .Monotonic);
            }
        }

        pub fn release(self: *Self) void {
            @atomicStore(
                u8,
                @ptrCast(*u8, &self.state),
                UNLOCKED,
                .Release,
            );

            const ordering = if (isX86) .Acquire else .Monotonic;
            const state = @atomicLoad(usize, &self.state, ordering);
            if ((state & WAITING != 0) and (state & (WAKING | LOCKED) == 0))
                self.releaseSlow(state);
        }

        fn releaseSlow(self: *Self, new_state: usize) void {
            @setCold(true);
            
            var state = new_state;
            while (true) {
                if ((state & WAITING == 0) or (state & (WAKING | LOCKED) != 0))
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

            const head = @intToPtr(*Waiter, state & WAITING);
            const tail = head.findTail();
            tail.event.set(false);
        }
    };
}