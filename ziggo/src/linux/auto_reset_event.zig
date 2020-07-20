const std = @import("std");
const linux = std.os.linux;
const system = @import("../system.zig");

pub const AutoResetEvent = extern struct {
    state: State,

    const State = extern enum(i32) {
        empty,
        waiting,
        notified,
    };

    pub fn init(self: *AutoResetEvent) void {
        self.* = AutoResetEvent{
            .state = .empty,
        };
    }

    pub fn deinit(self: *AutoResetEvent) void {
        const state = @atomicLoad(State, &self.state, .Monotonic);
        std.debug.assert(state != .waiting);
    }

    pub fn notify(self: *AutoResetEvent) void {
        var state = @atomicLoad(State, &self.state, .Monotonic);

        if (state == .empty) {
            state = @cmpxchgStrong(
                State,
                &self.state,
                .empty,
                .notified,
                .Release,
                .Monotonic,
            ) orelse return;
        }

        if (state == .notified)
            return;

        std.debug.assert(state == .waiting);
        @atomicStore(State, &self.state, .empty, .Release);
        self.notifyEvent();
    }

    pub fn wait(self: *AutoResetEvent) void {
        var state = @atomicLoad(State, &self.state, .Acquire);

        if (state == .empty) {
            state = @cmpxchgStrong(
                State,
                &self.state,
                .empty,
                .waiting,
                .Acquire,
                .Acquire,
            ) orelse return self.waitEvent();
        }

        std.debug.assert(state == .notified);
        @atomicStore(State, &self.state, .empty, .Monotonic);
    }

    fn notifyEvent(self: *AutoResetEvent) void {
        const ptr = @ptrCast(*const i32, &self.state);
        const rc = linux.futex_wake(ptr, linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG, 1);
        std.debug.assert(linux.getErrno(rc) == 0);
    }

    fn waitEvent(self: *AutoResetEvent) void {
        var spin: u4 = 0;
        while (spin <= 3) : (spin += 1) {
            if (@atomicLoad(State, &self.state, .Acquire) != .waiting)
                return;
            system.spinLoopHint(@as(usize, 1) << spin);
        }

        const ptr = @ptrCast(*const i32, &self.state);
        while (@atomicLoad(State, &self.state, .Acquire) == .waiting) {
            const rc = linux.futex_wait(ptr, linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG, @enumToInt(State.waiting), null);
            switch (linux.getErrno(rc)) {
                0 => continue,
                std.os.EINTR => continue,
                std.os.EAGAIN => break,
                else => unreachable,
            }
        }
    }
};