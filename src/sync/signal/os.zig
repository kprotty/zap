// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");

pub const Signal = struct {
    const EMPTY: usize = 0;
    const NOTIFIED: usize = 1;

    state: usize = EMPTY,

    pub fn init(self: *Signal) void {
        self.* = Signal{};
    }

    pub fn deinit(self: *Signal) void {
        self.* = undefined;
    }

    pub fn notifyHandoff(self: *Signal) void {
        return self.notify();
    }

    pub fn notify(self: *Signal) void {
        const state = @atomicRmw(usize, &self.state, .Xchg, NOTIFIED, .Release);

        if (state != EMPTY)
            self.notifySlow(state);
    }

    fn notifySlow(self: *Signal, state: usize) void {
        @setCold(true);

        if (state == NOTIFIED)
            std.debug.panic("Signal.notify() called when already notified", .{});

        OsEvent.notify(&self.state, state);
    }

    pub fn wait(self: *Signal) void {
        const state = @atomicLoad(usize, &self.state, .Acquire);

        if (state != NOTIFIED)
            self.waitSlow(state);

        @atomicStore(usize, &self.state, EMPTY, .Monotonic);
    }

    fn waitSlow(self: *Signal, current_state: usize) void {
        @setCold(true);
        
        var state = current_state;
        if (state != EMPTY)
            std.debug.panic("Signal.wait() called with active waiter", .{});

        state = OsEvent.get(&self.state);
        std.debug.assert(state != EMPTY and state != NOTIFIED);

        state = @cmpxchgStrong(
            usize,
            &self.state,
            EMPTY,
            state,
            .Release,
            .Acquire,
        ) orelse return OsEvent.wait(&self.state, state);

        if (state != NOTIFIED)
            std.debug.panic("Signal.wait() called when already waiting", .{});
    }

    pub fn canYield(iter: usize) bool {
        return iter <= 10;
    }

    pub fn yield(iter: usize) void {
        if (iter <= 3) {
            const shift = @intCast(std.math.Log2Int(usize), iter);
            std.SpinLock.loopHint(@as(usize, 1) << shift);
        } else {
            OsEvent.yield(iter);
        }
    }
};

const OsEvent = 
    if (std.builtin.os.tag == .windows)
        WindowsEvent
    else if (std.builtin.link_libc)
        PosixEvent
    else if (std.builtin.os.tag == .linux)
        LinuxEvent
    else
        @compileError("OS not supported");

const WindowsEvent = @compileError("TODO");

const PosixEvent = @compileError("TODO");

const LinuxEvent = struct {
    const linux = std.os.linux;

    const WAITING = 2;

    fn get(state: *usize) usize {
        return WAITING;
    }

    fn notify(state: *usize, _waiting: usize) void {
        const rc = linux.futex_wake(
            @ptrCast(*const i32, state),
            linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAKE,
            @as(i32, 1)
        );

        std.debug.assert(linux.getErrno(rc) == 0);
    }

    fn wait(state: *usize, waiting: usize) void {
        const compare = @intCast(i32, waiting);

        while (true) {
            const rc = linux.futex_wait(
                @ptrCast(*const i32, state),
                linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAIT,
                compare,
                null,
            );

            switch (linux.getErrno(rc)) {
                0 => {},
                std.os.EINTR => {},
                std.os.EAGAIN => return,
                std.os.ETIMEDOUT => unreachable,
                else => unreachable,
            }

            if (@atomicLoad(usize, state, .Acquire) != waiting)
                break;
        }
    }

    fn yield(iter: usize) void {
        std.os.sched_yield() catch unreachable;
    }
};

