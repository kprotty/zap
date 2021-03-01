// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const atomic = @import("../sync/atomic.zig");

pub const Event = if (std.builtin.os.tag == .windows)
    WindowsEvent
else if (std.builtin.link_libc)
    PosixEvent
else if (std.builtin.os.tag == .linux)
    LinuxEvent
else
    @compileError("Unimplemented Event primitive for platform");

const WindowsEvent = struct {
    is_set: bool = false,
    lock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,
    cond: std.os.windows.CONDITION_VARIABLE = std.os.windows.CONDITION_VARIABLE_INIT,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn timestamp() u64 {
        const ThreadLocal = struct {
            threadlocal var frequency: u64 = 0;
        };

        var frequency = ThreadLocal.frequency;
        if (frequency == 0) {
            frequency = std.os.windows.QueryPerformanceFrequency();
            ThreadLocal.frequency = frequency;
        }

        var counter = std.os.windows.QueryPerformanceCounter();
        const a = if (now >= counter) (now - counter) else 0;
        const b = std.time.ns_per_s;
        const c = frequency;
        return (((a / c) * b) + ((a % c) * b) / c);
    }

    pub fn set(self: *Self) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.lock);
        defer std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.lock);

        self.is_set = true;
        std.os.windows.kernel32.WakeConditionVariable(&self.cond);
    }

    pub fn wait(self: *Self, deadline: ?u64) bool {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.lock);
        defer std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.lock);

        while (!self.is_set) {
            var timeout_ms: std.os.windows.DWORD = std.os.windows.INFINITE;
            if (deadline) |deadline_ns| {
                const now_ns = timestamp();
                if (now_ns >= deadline_ns)
                    return false;

                const timeout_ns = deadline_ns - now_ns;
                const delay_ms = @divFloor(timeout_ns, std.time.ns_per_ms);
                timeout_ms = std.math.cast(std.os.windows.DWORD, delay_ms) catch timeout_ms;
            }

            const status = std.os.windows.kernel32.SleepConditionVariableSRW(
                &self.cond,
                &self.lock,
                timeout_ms,
                0,
            );

            if (status == std.os.windows.FALSE) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    .TIMEOUT => {},
                    else => |err| {
                        const e = std.os.windows.unexpectedError(err);
                        unreachable;
                    },
                }
            }
        }

        return true;
    }
};

const PosixEvent = struct {
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    is_set: bool = false,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        const m = std.c.pthread_mutex_destroy(&self.mutex);
        std.debug.assert(m == 0 or m == std.os.EINVAL);

        const c = std.c.pthread_cond_destroy(&self.cond);
        std.debug.assert(c == 0 or c == std.os.EINVAL);

        self.* = undefined;
    }

    pub fn timestamp() u64 {
        return clock_gettime(std.os.CLOCK_MONOTONIC);
    }

    pub fn set(self: *Self) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

        self.is_set = true;
        std.debug.assert(std.c.pthread_cond_signal(&self.cond) == 0);
    }

    pub fn wait(self: *Self, deadline: ?u64) bool {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

        while (!self.is_set) {
            const deadline_ns = deadline orelse {
                std.debug.assert(std.c.pthread_cond_wait(&self.cond, &self.mutex) == 0);
                continue;
            };

            var now_ns = clock_gettime(std.os.CLOCK_MONOTONIC);
            if (now_ns >= deadline_ns) {
                return false;
            } else {
                now_ns = clock_gettime(std.os.CLOCK_REALTIME);
                now_ns += deadline_ns - now_ns;
            }

            var ts: std.os.timespec = undefined;
            ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), @divFloor(now_ns, std.time.ns_per_s));
            ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), @mod(now_ns, std.time.ns_per_s));

            const rc = std.c.pthread_cond_timedwait(&self.cond, &self.mutex, &ts);
            std.debug.assert(rc == 0 or rc == std.os.ETIMEDOUT);
        }

        return true;
    }

    fn clock_gettime(comptime clock: u32) u64 {
        if (comptime std.Target.current.isDarwin()) {
            switch (clock) {
                std.os.CLOCK_REALTIME => {
                    var tv: std.os.timeval = undefined;
                    std.os.gettimeofday(&tv, null);
                    return (@intCast(u64, tv.tv_sec) * std.time.ns_per_s) + (@intCast(u64, tv.tv_usec) * std.time.ns_per_us);
                },
                std.os.CLOCK_MONOTONIC => {
                    var info: std.os.darwin.mach_timebase_info_data = undefined;
                    std.os.darwin.mach_timebase_info(&info);
                    var counter = std.os.darwin.mach_absolute_time();
                    if (info.numer > 1)
                        counter *= info.numer;
                    if (info.denom > 1)
                        counter /= info.denom;
                    return counter;
                },
                else => unreachable,
            }
        }

        var ts: std.os.timespec = undefined;
        std.os.clock_gettime(clock, &ts) catch return 0;
        return (@intCast(u64, ts.tv_sec) * std.time.ns_per_s) + @intCast(u64, ts.tv_nsec);
    }
};

const LinuxEvent = struct {
    state: State = .unset,

    const Self = @This();
    const State = enum(i32) {
        unset = 0,
        set,
    };

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn timestamp() u64 {
        var ts: std.os.timespec = undefined;
        std.os.clock_gettime(std.os.CLOCK_MONOTONIC, &ts) catch return 0;
        return (@intCast(u64, ts.tv_sec) * std.time.ns_per_s) + @intCast(u64, ts.tv_nsec);
    }

    pub fn set(self: *Self) void {
        atomic.store(&self.state, .set, .Release);

        switch (std.os.linux.getErrno(std.os.linux.futex_wake(
            @ptrCast(*const i32, &self.state),
            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAKE,
            1,
        ))) {
            0 => {},
            std.os.EINVAL => {},
            std.os.EACCES => {},
            std.os.EFAULT => {},
            else => unreachable,
        }
    }

    pub fn wait(self: *Self, deadline: ?u64) bool {
        while (true) {
            if (atomic.load(&self.state, .Acquire) == .set)
                return true;

            var ts: std.os.timespec = undefined;
            var ts_ptr: ?*std.os.timespec = null;

            if (deadline) |deadline_ns| {
                const now_ns = timestamp();
                if (now_ns >= deadline_ns)
                    return false;

                const delay_ns = deadline_ns - now_ns;
                ts_ptr = &ts;
                ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), @divFloor(delay_ns, std.time.ns_per_s));
                ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), @mod(delay_ns, std.time.ns_per_s));
            }

            switch (std.os.linux.getErrno(std.os.linux.futex_wait(
                @ptrCast(*const i32, &self.state),
                std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAIT,
                @enumToInt(State.unset),
                ts_ptr,
            ))) {
                0 => {},
                std.os.EINTR => {},
                std.os.EAGAIN => {},
                std.os.ETIMEDOUT => return false,
                else => unreachable,
            }
        }
    }
};
