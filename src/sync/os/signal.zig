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

pub const Signal = 
    if (std.builtin.os.tag == .windows)
        WindowsSignal
    else if (std.builtin.link_libc)
        PosixSignal
    else if (std.builtin.os.tag == .linux)
        LinuxSignal
    else
        @compileError("OS not supported");

const PosixSignal = extern struct {
    const State = extern enum {
        waiting,
        notified,
    };

    state: State,
    cond: pthread_t,
    mutex: pthread_t,

    pub fn init(self: *Signal) void {
        self.state = .waiting;
        std.debug.assert(pthread_cond_init(&self.cond, null) == 0);
        std.debug.assert(pthread_mutex_init(&self.mutex, null) == 0);
    }

    pub fn deinit(self: *Signal) void {
        std.debug.assert(pthread_cond_destroy(&self.cond) == 0);
        std.debug.assert(pthread_mutex_destroy(&self.mutex) == 0);
    }

    pub fn notify(self: *Signal) void {
        std.debug.assert(pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(pthread_mutex_unlock(&self.mutex) == 0);

        self.state = .notified;
        std.debug.assert(pthread_cond_signal(&self.cond) == 0);
    }

    pub fn wait(self: *Signal) void {
        std.debug.assert(pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(pthread_mutex_unlock(&self.mutex) == 0);

        while (self.state == .waiting)
            std.debug.assert(pthread_cond_wait(&self.cond, &self.mutex) == 0);

        self.state = .waiting;
    }

    pub fn yield() void {
        std.os.sched_yield() catch unreachable;
    }

    const pthread_t = extern struct {
        _opaque: [64]u8 align(16),
    };

    extern "c" fn pthread_cond_init(cond: *pthread_t, attr: ?*const c_void) callconv(.C) c_int;
    extern "c" fn pthread_cond_destroy(cond: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_wait(noalias cond: *pthread_t, noalias mutex: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_signal(cond: *pthread_t) callconv(.C) c_int;

    extern "c" fn pthread_mutex_init(mutex: *pthread_t, attr: ?*const c_void) callconv(.C) c_int;
    extern "c" fn pthread_mutex_destroy(mutex: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_lock(mutex: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_unlock(mutex: *pthread_t) callconv(.C) c_int;
};

const LinuxSignal = extern struct {
    const linux = std.os.linux;

    state: State,

    const State = extern enum(i32) {
        waiting = 0,
        notified = 1,
    };

    pub fn init(self: *Signal) void {
        self.state = .waiting;
    }

    pub fn deinit(self: *Signal) void {
        self.* = undefined;
    }

    pub fn notify(self: *Signal) void {
        @atomicStore(State, &self.state, .notified, .Release);

        const rc = linux.futex_wake(
            @ptrCast(*const i32, &self.state),
            linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAKE,
            @as(i32, 1)
        );

        std.debug.assert(linux.getErrno(rc) == 0);
    }

    pub fn wait(self: *Signal) void {
        while (true) {
            const rc = linux.futex_wait(
                @ptrCast(*const i32, &self.state),
                linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAIT,
                @enumToInt(State.waiting),
                null,
            );

            switch (linux.getErrno(rc)) {
                0 => {},
                std.os.EINTR => {},
                std.os.EAGAIN => break,
                std.os.ETIMEDOUT => unreachable,
                else => unreachable,
            }

            if (@atomicLoad(State, &self.state, .Acquire) != .waiting)
                break;
        }

        self.state = .waiting;
    }

    pub fn yield() void {
        PosixSignal.yield();
    }
};

// TODO: use NtKeyedEvent directly instead of going through std.ResetEvent
const WindowsSignal = extern struct {
    const windows = std.os.windows;
    
    event: [@sizeOf(std.ResetEvent)]u8 align(@alignOf(std.ResetEvent)),

    fn getEvent(self: *Signal) *std.ResetEvent {
        return @ptrCast(*std.ResetEvent, &self.event);
    }

    pub fn init(self: *Signal) void {
        self.getEvent().* = std.ResetEvent.init();
    }

    pub fn deinit(self: *Signal) void {
        self.getEvent().deinit();
    }

    pub fn notify(self: *Signal) void {
        self.getEvent().set();
    }

    pub fn wait(self: *Signal) void {
        const event = self.getEvent();
        event.wait();
        event.reset();
    }

    pub fn yield() void {
        windows.kernel32.Sleep(1);
    }
};