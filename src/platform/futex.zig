const std = @import("std");
const zap = @import("../zap.zig");

const core = zap.core;
const platform = zap.platform;
const Condition = core.sync.Condition;
const Atomic = core.sync.atomic.Atomic;

pub const Futex = extern struct {
    event: Event = undefined,

    pub fn wait(self: *Futex, deadline_ptr: ?*Timestamp, condition: *Condition) bool {
        const deadline = if (deadline_ptr) |ptr| ptr.* else null;
        return self.event.wait(deadline, condition, nanotime);
    }

    pub fn wake(self: *Futex) void {
        self.event.notify();
    }

    pub const Timestamp = u64;

    pub const nanotime = Clock.nanotime;

    pub fn timestamp(current: *Timestamp) void {
        current.* = nanotime();
    }

    pub fn timeSince(t1: *Timestamp, t2: *Timestamp) u64 {
        return t1.* - t2.*;
    }
};

const Event =
    if (platform.is_windows)
        @import("./windows/event.zig").Event
    else if (platform.link_libc and platform.is_posix)
        @import("./posix/event.zig").Event
    else if (platform.is_linux)
        @import("./linux/event.zig").Event
    else
        @compileError("OS thread blocking/unblocking not supported");

const Clock = struct {
    var last_lock = core.sync.Lock{};
    var last_now: Atomic(u64) = Atomic(u64).init(0);

    fn nanotime() u64 {
        const now = Event.nanotime(getCachedFrequency);
        if (Event.is_actually_monotonic)
            return now;

        if (std.meta.bitCount(usize) < 64) {
            last_lock.acquire(Futex);
            defer last_lock.release();

            const last = last_now;
            if (last > now)
                return last;

            last_now = now;
            return now;
        }

        var last = last_now.load(.relaxed);
        while (true) {
            if (last > now)
                return last;
            last = last_now.tryCompareAndSwap(
                last,
                now,
                .relaxed,
                .relaxed,
            ) orelse return now;
        }
    }

    fn ReturnTypeOf(comptime function: anytype) type {
        return @typeInfo(@TypeOf(function)).Fn.return_type.?;
    }

    fn getCachedFrequency(comptime getFrequencyFn: anytype) ReturnTypeOf(getFrequencyFn) {
        const Frequency = ReturnTypeOf(getFrequencyFn);
        const FrequencyState = enum(usize) {
            uninit,
            storing,
            init,
        };

        const Cached = struct {
            var frequency: Frequency = undefined;
            var frequenc_state = Atomic(FrequencyState).init(.uninit);
            
            fn get() Frequency {
                if (frequenc_state.load(.acquire) == .init)
                    return frequency;
                return getSlow();
            }

            fn getSlow() Frequency {
                @setCold(true);

                const local_frequency = getFrequencyFn();

                if (frequenc_state.compareAndSwap(
                    .uninit,
                    .storing,
                    .relaxed,
                    .relaxed,
                ) == null) {
                    frequency = local_frequency;
                    frequenc_state.store(.init, .release);
                }

                return local_frequency;
            }
        };

        return Cached.get();
    }
};