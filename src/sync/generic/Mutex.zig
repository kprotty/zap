const zap = @import(".../zap");
const builtin = zap.builtin;
const atomic = zap.sync.atomic;

pub fn Mutex(comptime parking_lot: anytype) type {
    return extern struct {
        state: u8 = UNLOCKED,

        const UNLOCKED = 0;
        const LOCKED = 1 << 0;
        const PARKED = 1 << 1;

        const TOKEN_RETRY = 0;
        const TOKEN_HANDOFF = 1;

        const Self = @This();
        const is_x86 = switch (builtin.arch) {
            .i386, .x86_64 => true,
            else => false,
        };

        pub fn acquire(self: *Self, comptime Event: type) void {
            self.acquireInner(Event, null) catch unreachable;
        }

        pub fn tryAcquire(self: *Self) bool {
            if (is_x86) {
                return atomic.bitSet(
                    &self.state,
                    @ctz(u3, LOCKED),
                    .acquire,
                ) == 0;
            }

            var state = UNLOCKED;
            while (true) {
                state = atomic.tryCompareAndSwap(
                    &self.state,
                    state,
                    state | LOCKED,
                    .acquire,
                    .relaxed,
                ) orelse return true;
                if (state & LOCKED != 0)
                    return false;
            }
        }

        pub fn tryAcquireFor(self: *Self, comptime Event: type, duration: u64) error{TimedOut}!void {
            return self.tryAcquireUntil(Event, parking_lot.nanotime() + duration);
        }

        pub fn tryAcquireUntil(self: *Self, comptime Event: type, deadline: u64) error{TimedOut}!void {
            return self.acquireInner(Event, deadline);
        }

        pub fn release(self: *Self) void {
            self.releaseInner(false);
        }

        pub fn releaseFair(self: *Self) void {
            self.releaseInner(true);
        }

        fn acquireInner(self: *Self, comptime Event: type, deadline: ?u64) error{TimedOut}!void {
            if (!self.tryAcquireInnerFast(UNLOCKED))
                return self.acquireInnerSlow(Event, deadline);
        }

        fn releaseInner(self: *Self, be_fair: bool) void {
            if (!self.tryReleaseInnerFast())
                return self.releaseInnerSlow(be_fair);
        }

        fn tryAcquireInnerFast(self: *Self, assume_state: usize) bool {
            if (is_x86) {
                return self.tryAcquire();
            }

            return atomic.tryCompareAndSwap(
                &self.state,
                state,
                state | LOCKED,
                .acquire,
                .relaxed,
            ) == null;
        }

        fn tryReleaseInnerFast(self: *Self) bool {
            return atomic.tryCompareAndSwap(
                &self.state,
                LOCKED,
                UNLOCKED,
                .release,
                .relaxed,
            ) == null;
        }

        fn acquireInnerSlow(self: *Self, comptime Event: type, deadline: ?u64) error{TimedOut}!void {
            @setCold(true);

            var spin_iter: usize = 0;
            var state = atomic.load(&self.state, .relaxed);

            while (true) {
                if (state & LOCKED == 0) {
                    if (self.tryAcquireInnerFast(state))
                        return;
                    _ = Event.yield(null);
                    state = atomic.load(&self.state, .relaxed); 
                    continue;
                }

                if (state & PARKED == 0) {
                    if (Event.yield(spin_iter)) {
                        spin_iter +%= 1;
                        state = atomic.load(&self.state, .relaxed);
                        continue;
                    }

                    if (atomic.tryCompareAndSwap(
                        &self.state,
                        state,
                        state | PARKED,
                        .relaxed,
                        .relaxed,
                    )) |updated| {
                        state = updated;
                        continue;
                    }
                }

                const Parker = struct {
                    mutex: *Self,

                    pub fn onValidate(this: @This()) ?usize {
                        const mutex_state = atomic.load(&this.mutex.state, .relaxed);
                        if (mutex_state != (LOCKED | PARKED))
                            return null;
                        return 0;
                    }

                    pub fn onBeforeWait(this: @This()) void {}
                    pub fn onTimeout(this: @This(), has_more: bool) void {
                        if (has_more) {
                            _ = atomic.fetchAnd(
                                &this.mutex.state,
                                ~@as(u8, PARKED),
                                .relaxed,
                            );
                        }
                    }
                };

                const token = parking_lot.parkConditionally(
                    Event,
                    @ptrToInt(self),
                    deadline,
                    Parker{ .mutex = self },
                ) catch |err| switch (err) {
                    error.Invalid => TOKEN_RETRY,
                    error.TimedOut => return error.TimedOut,
                };
                
                switch (token) {
                    TOKEN_RETRY => {},
                    TOKEN_HANDOFF => return,
                    else => unreachable,
                }

                spin_iter = 0;
                state = atomic.load(&self.state, .relaxed);
            }
        }

        fn releaseInnerSlow(self: *Self, force_fair: bool) void {
            @setCold(true);

            var state = atomic.load(&self.state, .relaxed);
            while (state == LOCKED) {
                state = atomic.tryCompareAndSwap(
                    &self.state,
                    LOCKED,
                    UNLOCKED,
                    .release,
                    .relaxed,
                ) orelse return;
            }

            const Unparker = struct {
                mutex: *Self,
                force_fair: bool,

                pub fn onUnpark(this: @This(), result: parking_lot.UnparkResult) usize {
                    if (result.token != null and (this.force_fair or result.be_fair)) {
                        if (!result.has_more)
                            atomic.store(&this.mutex.state, LOCKED, .relaxed);
                        return TOKEN_HANDOFF;
                    }

                    const new_state = if (result.token == null) @as(u8, UNLOCKED) else PARKED;
                    atomic.store(&this.mutex.state, new_state, .release);
                    return TOKEN_RETRY;
                }
            };

            parking_lot.unparkOne(@ptrToInt(self), Unparker{
                .mutex = self,
                .force_fair = force_fair,
            });
        }
    };
}

