const std = @import("std");
const linux = std.os.linux;

const core = @import("../../zap.zig").core;
const PosixEvent = @import("../posix/event.zig").Event;
const Atomic = core.sync.atomic.Atomic;

pub const Event = extern struct {
    state: Atomic(State) = undefined,

    const State = extern enum(i32) {
        empty,
        waiting,
        notified,
    };

    pub fn prepare(self: *Event) void {
        self.state.set(.waiting);
    }

    pub fn wait(self: *Event, deadline: ?u64) bool {
        var ts: linux.timespec = undefined;
        var ts_ptr: ?*linux.timespec = undefined;

        while (self.state.load(.acquire) == .waiting) {
            if (deadline) |deadline_ns| {
                const now = Event.nanotime();
                if (now > deadline_ns)
                    break;

                const ns = deadline_ns - now;
                ts_ptr = &ts;
                ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), @divFloor(ns, std.time.ns_per_s));
                ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), @mod(ns, std.time.ns_per_s));
            }

            const rc = linux.futex_wait(
                @ptrCast(*const i32, &self.state),
                linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAIT,
                @as(i32, @enumToInt(State.waiting)),
                ts_ptr,
            );

            switch (linux.getErrno(rc)) {
                linux.EAGAIN => return true,
                linux.EINTR => continue,
                linux.ETIMEDOUT => break,
                else => unreachable,
            }
        }

        return self.state.compareAndSwap(
            .waiting,
            .empty,
            .acquire,
            .acquire,
        ) != null;
    }

    pub fn notify(self: *Event) void {
        switch (self.state.swap(.notified, .release)) {
            .empty => {},
            .notified => unreachable, // notified an Event which was already notified
            .waiting => {
                const rc = linux.futex_wake(
                    @ptrCast(*const i32, &self.state),
                    linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAKE,
                    @as(i32, 1),
                );

                std.debug.assert(linux.getErrno(rc) == 0);
                std.debug.assert(rc == 0 or rc == 1); 
            }
        }
    }

    pub fn yield() void {
        _ = linux.sched_yield();
    }

    pub const is_monotonic = !( 
        (core.arch_tag == .s390x) or
        (core.is_arm and std.meta.bitCount(usize) == 64)
    );

    pub fn nanotime() u64 {
        return PosixEvent.nanotime();
    }
};
