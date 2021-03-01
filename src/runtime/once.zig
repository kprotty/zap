// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const atomic = @import("../sync/atomic.zig");

pub const Once = if (std.builtin.os.tag == .windows)
    WindowsOnce
else if (std.Target.current.isDarwin())
    DispatchOnce
else if (std.builtin.link_libc)
    PosixOnce
else if (std.builtin.os.tag == .linux)
    LinuxOnce
else
    @compileError("Platform does not support Once implementation");

const WindowsOnce = struct {
    once: std.os.windows.INIT_ONCE = std.os.windows.INIT_ONCE_STATIC_INIT,

    const Self = @This();

    pub fn call(self: *Self, comptime onceFn: fn () void) void {
        const Wrapper = struct {
            fn function(
                once: *std.os.windows.INIT_ONCE,
                parameter: ?std.os.windows.PVOID,
                context: ?std.os.windows.PVOID,
            ) std.os.windows.BOOL {
                onceFn();
                return std.os.windows.TRUE;
            }
        };

        const status = std.os.windows.InitOnceExecuteOnce(&self.once, Wrapper.function, null, null);
        if (status != std.os.windows.FALSE) {
            const err = std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
            unreachable;
        }
    }
};

const DispatchOnce = struct {
    once: dispatch_once_t = 0,

    const Self = @This();
    const dispatch_once_t = usize;
    const dispatch_function_t = fn (?*c_void) callconv(.C) void;
    extern fn dispatch_once_f(
        predicate: *dispatch_once_t,
        context: ?*c_void,
        function: dispatch_function_t,
    ) void;

    pub fn call(self: *Self, comptime onceFn: fn () void) void {
        const Wrapper = struct {
            fn function(_: ?*c_void) callconv(.C) void {
                return onceFn();
            }
        };
        dispatch_once_f(&self.once, null, Wrapper.function);
    }
};

const LinuxOnce = struct {
    state: State = .Uninit,

    const Self = @This();
    const State = enum(i32) {
        Uninit,
        Calling,
        Waiting,
        Called,
    };

    pub fn call(self: *Self, comptime onceFn: fn () void) void {
        const state = atomic.load(&self.state, .Acquire);
        if (state != .Called)
            self.callSlow(onceFn, state);
    }

    fn callSlow(self: *Self, comptime onceFn: fn () void, current_state: State) void {
        @setCold(true);

        var state = current_state;
        while (true) {
            switch (state) {
                .Uninit => {
                    if (atomic.tryCompareAndSwap(
                        &self.state,
                        state,
                        .Calling,
                        .Acquire,
                        .Acquire,
                    )) |updated| {
                        atomic.spinLoopHint();
                        state = updated;
                        continue;
                    }

                    defer if (atomic.swap(&self.state, .Called, .Release) == .Waiting) {
                        switch (std.os.linux.getErrno(std.os.linux.futex_wake(
                            @ptrCast(*const i32, &self.lock.state),
                            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAKE,
                            std.math.maxInt(i32),
                        ))) {
                            0 => {},
                            std.os.EINVAL => {},
                            std.os.EACCES => {},
                            std.os.EFAULT => {},
                            else => unreachable,
                        }
                    };

                    onceFn();
                    return;
                },
                .Calling => {
                    state = atomic.tryCompareAndSwap(
                        &self.state,
                        state,
                        .Waiting,
                        .Acquire,
                        .Acquire,
                    ) orelse State.Waiting;
                    atomic.spinLoopHint();
                },
                .Waiting => {
                    defer state = atomic.load(&self.state, .Acquire);
                    switch (std.os.linux.getErrno(std.os.linux.futex_wait(
                        @ptrCast(*const i32, &self.state),
                        std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAIT,
                        @enumToInt(State.Waiting),
                        null,
                    ))) {
                        0 => {},
                        std.os.EINTR => {},
                        std.os.EAGAIN => {},
                        std.os.ETIMEDOUT => unreachable,
                        else => unreachable,
                    }
                },
                .Called => {
                    return;
                },
            }
        }
    }
};

const PosixOnce = struct {
    state: usize = 0,

    const Self = @This();
    const State = enum(u2) {
        Uninit = 0,
        Calling = 1,
        Called = 2,
    };

    const Event = @import("./event.zig").Event;
    const Waiter = struct {
        event: Event align(std.math.max(@alignOf(Event), 4)) = .{},
        next: ?*Waiter = undefined,
    };

    pub fn call(self: *Self, comptime onceFn: fn () void) void {
        var state = atomic.load(&self.state, .Acquire);
        if (@intToEnum(State, @truncate(u2, state)) != .Called)
            self.callSlow(onceFn, state);
    }

    fn callSlow(self: *Self, comptime onceFn: fn () void, current_state: usize) void {
        @setCold(true);

        var has_waiter = false;
        var waiter: Waiter = undefined;
        var state = current_state;

        while (true) {
            switch (@intToEnum(State, @truncate(u2, state))) {
                .Uninit => {
                    if (atomic.tryCompareAndSwap(
                        &self.state,
                        state,
                        @enumToInt(State.Calling),
                        .Acquire,
                        .Acquire,
                    )) |updated| {
                        atomic.spinLoopHint();
                        state = updated;
                        continue;
                    }

                    onceFn();
                    state = atomic.swap(&self.state, @enumToInt(State.Completed), .AcqRel);

                    var waiters = @intToPtr(?*Waiter, state & ~@as(usize, 0b11));
                    while (waiters) |waiter| {
                        waiters = waiter.next;
                        waiter.event.set();
                    }

                    return;
                },
                .Calling => {
                    if (!has_waiter) {
                        waiter = Waiter{};
                        has_waiter = true;
                    }

                    waiter.next = @intToPtr(?*Waiter, state & ~@as(usize, 0b11));
                    if (atomic.tryCompareAndSwap(
                        &self.state,
                        state,
                        @ptrToInt(&waiter) | @enumToInt(State.Calling),
                        .AcqRel,
                        .Acquire,
                    )) |updated| {
                        atomic.spinLoopHint();
                        state = updated;
                        continue;
                    }

                    std.debug.assert(waiter.event.wait(null));
                    waiter.event.deinit();
                    return;
                },
                .Called => {
                    return;
                },
            }
        }
    }
};
