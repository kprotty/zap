// https://github.com/daurnimator/zig-timeout-wheel/
  
// Ported from https://github.com/wahern/timeout/

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const rotl = std.math.rotl;
const rotr = std.math.rotr;

fn fls(n: anytype) usize {
    return @TypeOf(n).bit_count - @clz(@TypeOf(n), n);
}

fn ctz(x: anytype) @TypeOf(x) {
    return @ctz(@TypeOf(x), x);
}

fn IntType(comptime is_signed: bool, comptime bits: anytype) type {
    return @Type(std.builtin.TypeInfo{
        .Int = std.builtin.TypeInfo.Int{
            .bits = bits,
            .is_signed = is_signed,
        },
    });
}

/// wheel_bit - The number of value bits mapped in each wheel. The
///             lowest-order wheel_bit bits index the lowest-order (highest
///             resolution) wheel, the next group of wheel_bit bits the
///             higher wheel, etc.
/// wheel_num - The number of wheels. wheel_bit * wheel_num = the number of
///             value bits used by all the wheels. Any timeout value
///             larger than this will cycle through again.
pub fn TimeoutWheel(
    comptime timeout_t: type,
    wheel_bit: comptime_int,
    wheel_num: comptime_int,
    intervals: enum {
        NoIntervals,
        AllowIntervals,
    },
    relative_access: enum {
        NoRelative,
        AllowRelative,
    },
) type {
    const abstime_t = timeout_t;
    const reltime_t = timeout_t;

    assert(wheel_bit > 0);
    assert(wheel_num > 0);
    assert(((1 << (wheel_bit * wheel_num)) - 1) <= std.math.maxInt(timeout_t));

    const wheel_t = IntType(false, 1 << wheel_bit);
    const wheel_len = (1 << wheel_bit);
    const wheel_max = (wheel_len - 1);
    const wheel_mask = (wheel_len - 1);
    const wheel_num_t = std.math.Log2Int(IntType(false, wheel_num));
    const wheel_slot_t = IntType(false, wheel_bit);

    return struct {
        const Self = @This();
        const TimeoutWheelType = Self;

        const TimeoutType = timeout_t;

        const TimeoutList = std.TailQueue(void);

        /// Public Timeout structure
        pub const Timeout = struct {
            // intrusive LinkedList
            node: TimeoutList.Node,

            /// absolute expiration time
            expires: abstime_t,

            /// Timeout list if pending on wheel or expiry queue
            pending: ?*TimeoutList,

            /// Timeout interval if periodic
            /// rather than using an optional type we internally use 0 to indicate no interval
            interval: if (intervals == .AllowIntervals) reltime_t else void,

            /// timeouts collection if member of
            timeouts: if (relative_access == .AllowRelative) ?*TimeoutWheelType else void,

            /// initialize Timeout structure
            pub fn init(init_interval: ?reltime_t) Timeout {
                return Timeout{
                    .node = TimeoutList.Node{ .data = undefined },
                    .expires = 0,
                    .pending = null,
                    .interval = init: {
                        if (intervals == .AllowIntervals) {
                            if (init_interval) |int| {
                                assert(int > 0);
                                break :init int;
                            } else {
                                break :init 0;
                            }
                        } else {
                            assert(init_interval == null);
                        }
                    },
                    .timeouts = if (relative_access == .AllowRelative) null,
                };
            }

            fn setTimeouts(self: *Timeout, T: ?*TimeoutWheelType) void {
                if (relative_access == .AllowRelative) {
                    self.timeouts = T;
                }
            }

            /// true if on timing wheel, false otherwise
            pub fn isPending(self: *Timeout) (if (relative_access == .AllowRelative) bool else void) {
                if (relative_access == .AllowRelative) {
                    if (self.pending) |p| {
                        return p != &self.timeouts.?.expiredList;
                    }
                    return false;
                }
            }

            /// true if on expired queue, false otherwise
            pub fn isExpired(self: *Timeout) (if (relative_access == .AllowRelative) bool else void) {
                if (relative_access == .AllowRelative) {
                    if (self.pending) |p| {
                        return p == &self.timeouts.?.expiredList;
                    }
                    return false;
                }
            }

            /// remove timeout from any timing wheel (okay if not member of any)
            pub fn remove(self: *Timeout) void {
                if (relative_access == .AllowRelative) {
                    self.timeouts.?.remove(self);
                }
            }
        };

        /// Allocate and initialize a Timeout and its data.
        ///
        /// Arguments:
        ///     allocator: Dynamic memory allocator.
        ///
        /// Returns:
        ///     A pointer to the new timeout.
        pub fn createTimeout(self: *Self, interval: ?reltime_t, allocator: *Allocator) !*Timeout {
            const t = try allocator.create(Timeout);
            t.* = Timeout.init(interval);
            return t;
        }

        /// Deallocate a Timeout.
        ///
        /// Arguments:
        ///     Timeout: Pointer to the Timeout to deallocate.
        ///     allocator: Dynamic memory allocator.
        pub fn destroyTimeout(self: *Self, to: *Timeout, allocator: *Allocator) void {
            allocator.destroy(to);
        }

        wheel: [wheel_num][wheel_len]TimeoutList,
        expiredList: TimeoutList,
        pendingWheels: [wheel_num]wheel_t,
        curtime: abstime_t,

        pub fn init() Self {
            return Self{
                .wheel = init: {
                    var initial_value: [wheel_num][wheel_len]TimeoutList = undefined;
                    for (initial_value) |*pt| {
                        pt.* = nested: {
                            var nested_value: [wheel_len]TimeoutList = undefined;
                            for (nested_value) |*npt| {
                                npt.* = TimeoutList{};
                            }
                            break :nested nested_value;
                        };
                    }
                    break :init initial_value;
                },
                .expiredList = TimeoutList{},
                .pendingWheels = [_]wheel_t{0} ** wheel_num,
                .curtime = 0,
            };
        }

        pub fn reset(self: *Self) void {
            var resetList = TimeoutList{};

            for (self.wheel) |*wheel| {
                for (wheel) |*slot_ptr| {
                    resetList.concatByMoving(slot_ptr);
                }
            }

            resetList.concatByMoving(&self.expiredList);

            {
                var it = resetList.first;
                while (it) |node| : (it = node.next) {
                    var to: *Timeout = @fieldParentPtr(Timeout, "node", node);
                    to.pending = null;
                    to.setTimeouts(null);
                }
            }
        }

        pub fn remove(self: *Self, to: *Timeout) void {
            if (to.pending) |to_pending| {
                to_pending.remove(&to.node);

                if ((to_pending != &self.expiredList) and (to_pending.first == null)) {
                    // TODO: use pointer subtraction. See https://github.com/ziglang/zig/issues/1738
                    const index = (@ptrToInt(to_pending) - @ptrToInt(&self.wheel[0][0])) / @sizeOf(TimeoutList);
                    const wheel = @intCast(wheel_num_t, index / wheel_len);
                    const slot = @intCast(wheel_slot_t, index % wheel_len);

                    self.pendingWheels[wheel] &= ~(@as(wheel_t, 1) << slot);
                }

                to.pending = null;
                to.setTimeouts(null);
            }
        }

        fn timeout_rem(self: *const Self, to: *Timeout) reltime_t {
            return to.expires - self.curtime;
        }

        fn timeout_wheel(t: timeout_t) wheel_num_t {
            assert(t > 0); // must be called with timeout != 0, so fls input is nonzero
            return @intCast(wheel_num_t, (@intCast(std.math.Log2Int(timeout_t), fls(std.math.min(t, std.math.maxInt(timeout_t)))) - 1) / wheel_bit);
        }

        fn timeout_slot(wheel: wheel_num_t, expires: timeout_t) wheel_slot_t {
            return @truncate(wheel_slot_t, (expires >> (@intCast(std.math.Log2Int(timeout_t), wheel) * wheel_bit)) - if (wheel != 0) @as(u1, 1) else 0);
        }

        fn sched(self: *Self, to: *Timeout, expires: timeout_t) void {
            self.remove(to);
            to.expires = expires;

            to.setTimeouts(self);

            if (expires > self.curtime) {
                const rem = self.timeout_rem(to);

                // rem is nonzero since:
                //   rem == timeout_rem(T, td),
                //       == to.expires - self.curtime
                //   and above we have expires > self.curtime.
                const wheel = timeout_wheel(rem);
                const slot = timeout_slot(wheel, to.expires);

                to.pending = &self.wheel[wheel][slot];
                to.pending.?.append(&to.node);

                self.pendingWheels[wheel] |= @as(wheel_t, 1) << slot;
            } else {
                to.pending = &self.expiredList;
                to.pending.?.append(&to.node);
            }
        }

        /// add timeout to timing wheel
        pub fn add(self: *Self, to: *Timeout, ticks: timeout_t) void {
            self.sched(to, self.curtime + ticks);
        }

        /// update timing wheel with current absolute time
        pub fn update(self: *Self, curtime: abstime_t) void {
            var elapsed: abstime_t = curtime - self.curtime;
            var todo = TimeoutList{};

            for (self.pendingWheels) |*slot_mask, wheel| {
                var pending_slots: wheel_t = undefined;

                // Calculate the slots expiring in this wheel
                //
                // If the elapsed time is greater than the maximum period of
                // the wheel, mark every position as expiring.
                //
                // Otherwise, to determine the expired slots fill in all the
                // bits between the last slot processed and the current
                // slot, inclusive of the last slot. We'll bitwise-AND this
                // with our pending set below.
                //
                // If a wheel rolls over, force a tick of the next higher
                // wheel.
                const wheel_offset = @intCast(std.math.Log2Int(abstime_t), wheel) * wheel_bit;
                if ((elapsed >> wheel_offset) > wheel_max) {
                    pending_slots = ~@as(wheel_t, 0);
                } else {
                    const _elapsed = @truncate(wheel_slot_t, elapsed >> wheel_offset);

                    const oslot = self.curtime >> wheel_offset;
                    // https://github.com/ziglang/zig/issues/1739
                    pending_slots = rotl(wheel_t, (@as(wheel_t, 1) << _elapsed) - 1, @intCast(wheel_t, oslot));

                    const nslot = @truncate(wheel_slot_t, curtime >> wheel_offset);
                    // https://github.com/ziglang/zig/issues/1739
                    pending_slots |= @as(wheel_t, 1) << nslot;
                }

                while ((pending_slots & slot_mask.*) != 0) {
                    // ctz input cannot be zero: loop condition.
                    const slot = @truncate(wheel_slot_t, ctz(pending_slots & slot_mask.*));
                    todo.concatByMoving(&self.wheel[wheel][slot]);
                    slot_mask.* &= ~(@as(wheel_t, 1) << slot);
                }

                if ((0x1 & pending_slots) == 0)
                    break; // break if we didn't wrap around end of wheel

                // if we're continuing, the next wheel must tick at least once
                elapsed = std.math.max(elapsed, @as(abstime_t, wheel_len) << wheel_offset);
            }

            self.curtime = curtime;

            while (todo.first) |node| {
                var to = @fieldParentPtr(Timeout, "node", node);

                todo.remove(node);
                to.pending = null;

                self.sched(to, to.expires);
            }
        }

        /// step timing wheel by relative time
        pub fn step(self: *Self, elapsed: reltime_t) void {
            self.update(self.curtime + elapsed);
        }

        // return true if any timeouts pending on timing wheel
        pub fn pending(self: *const Self) bool {
            var pending_slots: wheel_t = 0;

            for (self.pendingWheels) |slot_mask| {
                pending_slots |= slot_mask;
            }

            return pending_slots != 0;
        }

        /// return true if any timeouts on expired queue
        pub fn expired(self: *const Self) bool {
            return self.expiredList.first != null;
        }

        /// Calculate the interval before needing to process any timeouts pending on
        /// any wheel.
        ///
        /// This might return a timeout value sooner than any installed timeout if
        /// only higher-order wheels have timeouts pending. We can only know when to
        /// process a wheel, not precisely when a timeout is scheduled. Our timeout
        /// accuracy could be off by 2^(N*M)-1 units where N is the wheel number and
        /// M is wheel_bit. Only timeouts which have fallen through to wheel 0 can be
        /// known exactly.
        ///
        /// We never return a timeout larger than the lowest actual timeout.
        pub fn timeout(self: *const Self) reltime_t {
            if (self.expiredList.first != null) {
                return 0;
            }

            var interval = ~@as(timeout_t, 0);
            var relmask: timeout_t = 0;

            for (self.pendingWheels) |slot_mask, wheel| {
                if (slot_mask != 0) {
                    const slot = @truncate(wheel_slot_t, self.curtime >> (@intCast(std.math.Log2Int(timeout_t), wheel) * wheel_bit));

                    var _timeout: timeout_t = undefined;

                    {
                        // ctz input cannot be zero: self.pending[wheel] is
                        // nonzero, so rotr() is nonzero.
                        // https://github.com/ziglang/zig/issues/1739
                        const tmp = ctz(rotr(wheel_t, slot_mask, @as(wheel_t, slot)));
                        // +1 to higher order wheels as those timeouts are one rotation in the future (otherwise they'd be on a lower wheel or expired)
                        _timeout = @as(timeout_t, tmp + if (wheel != 0) @as(u1, 1) else 0) << (@intCast(std.math.Log2Int(timeout_t), wheel) * wheel_bit);
                    }

                    _timeout -= relmask & self.curtime;
                    // reduce by how much lower wheels have progressed

                    interval = std.math.min(_timeout, interval);
                }

                relmask <<= wheel_bit;
                relmask |= wheel_mask;
            }

            return interval;
        }

        /// return any expired timeout (caller should loop until NULL-return)
        pub fn get(self: *Self) ?*Timeout {
            const node = self.expiredList.first orelse return null;
            const to = @fieldParentPtr(Timeout, "node", node);

            self.expiredList.remove(node);
            to.pending = null;
            to.setTimeouts(null);

            if (intervals == .AllowIntervals and to.interval != 0) {
                to.expires += to.interval;

                if (to.expires <= self.curtime) {
                    // If we've missed the next firing of this timeout, reschedule
                    // it to occur at the next multiple of its interval after
                    // the last time that it fired.
                    const n = self.curtime - to.expires;
                    const r: timeout_t = n % to.interval;
                    to.expires = self.curtime + (to.interval - r);
                }

                self.sched(to, to.expires);
            }

            return to;
        }
    };
}

const DefaultTimeoutWheel = TimeoutWheel(u64, 6, 4, .AllowIntervals, .AllowRelative);

test "timeout_wheel" {
    assert(DefaultTimeoutWheel.timeout_wheel(1) == 0);
    assert(DefaultTimeoutWheel.timeout_wheel(1 << 6) == 1);
    assert(DefaultTimeoutWheel.timeout_wheel(1 << 12) == 2);
    assert(DefaultTimeoutWheel.timeout_wheel(1 << 18) == 3);
}

test "basic test" {
    const allocator = std.debug.global_allocator;

    inline for ([]type{
        DefaultTimeoutWheel,
        // test with all flag combinations
        TimeoutWheel(u64, 6, 4, .NoIntervals, .AllowRelative),
        TimeoutWheel(u64, 6, 4, .AllowIntervals, .NoRelative),
        TimeoutWheel(u64, 6, 4, .NoIntervals, .NoRelative),
        // test with some different bit sizes
        TimeoutWheel(u128, 11, 4, .AllowIntervals, .AllowRelative),
        TimeoutWheel(u64, 10, 4, .AllowIntervals, .AllowRelative),
        TimeoutWheel(u64, 9, 4, .AllowIntervals, .AllowRelative),
        TimeoutWheel(u64, 8, 4, .AllowIntervals, .AllowRelative),
        TimeoutWheel(u64, 7, 4, .AllowIntervals, .AllowRelative),
        TimeoutWheel(u64, 5, 4, .AllowIntervals, .AllowRelative),
        TimeoutWheel(u64, 4, 4, .AllowIntervals, .AllowRelative),
        TimeoutWheel(u64, 3, 4, .AllowIntervals, .AllowRelative),
        // different timeout sizes
        TimeoutWheel(u128, 3, 4, .AllowIntervals, .AllowRelative),
        TimeoutWheel(u32, 3, 4, .AllowIntervals, .AllowRelative),
        TimeoutWheel(u16, 3, 4, .AllowIntervals, .AllowRelative),
        TimeoutWheel(u8, 2, 2, .AllowIntervals, .AllowRelative),
    }) |TimeoutWheelType| {
        var mywheel = TimeoutWheelType.init();
        assert(mywheel.pending() == false);
        assert(mywheel.expired() == false);
        assert(mywheel.timeout() >= 0);
        const mytimeout = try mywheel.createTimeout(null, allocator);
        defer mywheel.destroyTimeout(mytimeout, allocator);
        mywheel.add(mytimeout, 5);
        assert(mywheel.pending() == true);
        assert(mywheel.expired() == false);
        assert(mywheel.timeout() <= 5);
        assert(mywheel.get() == null);
        mywheel.step(1);
        assert(mywheel.pending() == true);
        assert(mywheel.expired() == false);
        assert(mywheel.timeout() <= 4);
        assert(mywheel.get() == null);
        // step to one step before the timer should fire
        mywheel.step(3);
        assert(mywheel.pending() == true);
        assert(mywheel.expired() == false);
        assert(mywheel.timeout() == 1);
        assert(mywheel.get() == null);
        mywheel.step(1);
        assert(mywheel.pending() == false);
        assert(mywheel.expired() == true);
        assert(mywheel.timeout() == 0);
        assert(mywheel.get() == mytimeout);
        assert(mywheel.pending() == false);
        assert(mywheel.expired() == false);
        assert(mywheel.timeout() >= 0);
        assert(mywheel.get() == null);

        // test remove
        mywheel.add(mytimeout, 5);
        assert(mywheel.pending() == true);
        assert(mywheel.expired() == false);
        assert(mywheel.timeout() <= 5);
        assert(mywheel.get() == null);
        mywheel.remove(mytimeout);
        assert(mywheel.pending() == false);
        assert(mywheel.expired() == false);
        assert(mywheel.timeout() >= 0);
        assert(mywheel.get() == null);
    }
}