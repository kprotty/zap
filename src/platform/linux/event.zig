const std = @import("std");
const zap = @import("../../zap.zig");
const PosixEvent = @import("../posix/event.zig").Event;

const system = std.os.system;
const core = zap.core;
const platform = zap.platform;

const Condition = core.sync.Condition;
const Atomic = core.sync.atomic.Atomic;

pub const Event = extern struct {
    state: Atomic(State) = undefined,

    const State = extern enum(i32) {
        waiting,
        notified,
    };

    pub fn wait(self: *Event, deadline: ?u64, condition: *Condition, comptime nanotimeFn: anytype) bool {
        self.state.set(.waiting);

        if (condition.isMet())
            return true;

        var ts: system.timespec = undefined;
        var ts_ptr: ?*system.timespec = null;

        while (true) {
            switch (self.state.load(.acquire)) {
                .waiting => {},
                .notified => return true,
            }

            if (deadline) |deadline_ns| {
                const now = nanotimeFn();
                if (now > deadline_ns)
                    return false;

                const duration = deadline_ns - now;
                ts_ptr = &ts;
                ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), @divFloor(duration, std.time.ns_per_s));
                ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), @mod(duration, std.time.ns_per_s));
            }

            const rc = system.futex_wait(
                @ptrCast(*const i32, &self.state),
                system.FUTEX_PRIVATE_FLAG | system.FUTEX_WAIT,
                @as(i32, @enumToInt(State.waiting)),
                ts_ptr,
            );

            switch (system.getErrno(rc)) {
                0 => continue,
                system.EINTR => continue,
                system.EAGAIN => return true,
                system.ETIMEDOUT => return false,
                else => @panic("futex(WAIT) unhandled errno code"),
            }
        }
    }

    pub fn notify(self: *Event) void {
        self.state.store(.notified, .release);

        const rc = system.futex_wake(
            @ptrCast(*const i32, &self.state),
            system.FUTEX_PRIVATE_FLAG | system.FUTEX_WAKE,
            @as(i32, 1),
        );

        switch (system.getErrno(rc)) {
            0 => {},
            system.EFAULT => {},
            else => @panic("futex(WAKE) unhandled errno"),
        }
    }

    pub const nanotime = PosixEvent.nanotime;

    pub const is_actually_monotonic = switch (platform.os_type) {
        .linux => core.arch_type != .aarch64 and .arch_type != .s390x,
        .openbsd => core.arch_type != .x86_64,
        else => true,
    };
};