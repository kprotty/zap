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
const zap = @import("../../zap.zig");

const os_nanotime = @import("../../time/clock.zig").nanotime;

fn spinLoopHint(iter: usize) void {
    const spin = @as(usize, 1) << @intCast(std.math.Log2Int(usize), iter);
    zap.sync.spinLoopHint(spin);
}

pub const Signal = 
    if (std.builtin.os.tag == .windows)
        WindowsSignal
    else if (std.builtin.link_libc)
        PosixSignal
    else if (std.builtin.os.tag == .linux)
        LinuxSignal
    else
        @compileError("OS not supported");

const WindowsSignal = extern struct {
    const windows = std.os.windows;

    const EMPTY: usize = 0;
    const NOTIFIED: usize = 1;
    
    state: usize = EMPTY,

    pub fn init(self: *Signal) void {
        self.* = Signal{};
    }

    pub fn deinit(self: *Signal) void {
        self.* = undefined;
    }

    pub inline fn notifyHandoff(self: *Signal) void {
        return self.notifyFast(true);
    }

    pub inline fn notify(self: *Signal) void {
        return self.notifyFast(false);
    }

    fn notifyFast(self: *Signal, comptime handoff: bool) void {
        const state = @atomicRmw(
            usize,
            &self.state,
            .Xchg,
            NOTIFIED,
            .AcqRel,
        );

        if (state > NOTIFIED)
            self.notifySlow(state, handoff);
    }

    fn notifySlow(self: *Signal, state: usize, comptime handoff: bool) void {
        @setCold(true);

        const tid_ptr = @intToPtr(*const windows.DWORD, state);
        const tid = @intToPtr(windows.PVOID, tid_ptr.*);

        const status = NtAlertThreadByThreadId(tid);
        std.debug.assert(status == .SUCCESS);
    }

    pub fn wait(self: *Signal) void {
        std.debug.assert(self.waitFast(null));
    }

    pub fn timedWait(self: *Signal, timeout: u64) error{TimedOut}!void {
        if (!self.waitFast(timeout))
            return error.TimedOut;
    }

    fn waitFast(self: *Signal, timeout: ?u64) bool {
        const state = @atomicLoad(usize, &self.state, .Acquire);

        if ((state != NOTIFIED) and !self.waitSlow(state, timeout))
            return false;

        @atomicStore(usize, &self.state, EMPTY, .Monotonic);
        return true;
    }

    fn waitSlow(self: *Signal, current_state: usize, timeout: ?u64) bool {
        @setCold(true);

        var state = current_state;
        var thread_id = windows.kernel32.GetCurrentThreadId();
        
        while (true) {
            if (state == NOTIFIED)
                return true;
            if (state != EMPTY)
                std.debug.panic("multiple waiters on the same Signal", .{});
            state = @cmpxchgWeak(
                usize,
                &self.state,
                state,
                @ptrToInt(&thread_id),
                .Release,
                .Acquire,
            ) orelse break;
        }

        var deadline: ?u64 = null;
        var ts: windows.LARGE_INTEGER = undefined;
        var ts_ptr: ?*windows.LARGE_INTEGER = null;

        while (true) {
            if (timeout) |timeout_ns| {
                var delay: u64 = undefined;
                
                if (deadline) |deadline_ns| {
                    const now = os_nanotime();
                    if (now >= deadline_ns) {
                        return @cmpxchgStrong(
                            usize,
                            &self.state,
                            @ptrToInt(&thread_id),
                            EMPTY,
                            .Acquire,
                            .Acquire,
                        ) != null;
                    } else {
                        delay = deadline_ns - now;
                    }
                } else {
                    delay = timeout_ns;
                    deadline = os_nanotime() + delay;
                }

                ts = @intCast(isize, delay);
                ts = -@divFloor(ts, 100);
                ts_ptr = &ts;
            }

            switch (NtWaitForAlertByThreadId(
                @intToPtr(windows.PVOID, thread_id),
                ts_ptr,
            )) {
                .SUCCESS => {},
                .ALERTED => {},
                .TIMEOUT => {},
                .USER_APC => {},
                else => unreachable,
            }

            state = @atomicLoad(usize, &self.state, .Acquire);
            if (state == NOTIFIED)
                return true;
            if (state != @ptrToInt(&thread_id))
                std.debug.panic("invalid state pointer when waiting", .{});
        }
    }

    pub fn yield(iter: usize) bool {
        if (iter > 10)
            return false;

        if (iter <= 3) {
            spinLoopHint(iter);
        } else {
            windows.kernel32.Sleep(1);
        } 

        return true;
    }

    pub fn nanotime() u64 {
        return os_nanotime();
    }

    extern "NtDll" fn NtAlertThreadByThreadId(
        thread_id: windows.PVOID,
    ) callconv(.Stdcall) windows.NTSTATUS;

    extern "NtDll" fn NtWaitForAlertByThreadId(
        thread_id: windows.PVOID,
        timeout: ?*windows.LARGE_INTEGER,
    ) callconv(.Stdcall) windows.NTSTATUS;
};

const LinuxSignal = extern struct {
    const linux = std.os.linux;

    state: State,

    const State = extern enum(i32) {
        empty,
        waiting,
        notified,
    };

    pub fn init(self: *Signal) void {
        self.state = .empty;
    }

    pub fn deinit(self: *Signal) void {
        self.* = undefined;
    }

    pub inline fn notifyHandoff(self: *Signal) void {
        return self.notifyFast(true);
    }

    pub inline fn notify(self: *Signal) void {
        return self.notifyFast(false);
    }

    fn notifyFast(self: *Signal, comptime handoff: bool) void {
        const state = @atomicRmw(
            State,
            &self.state,
            .Xchg,
            .notified,
            .Release,
        );

        if (state == .waiting)
            self.notifySlow(handoff);
    }

    fn notifySlow(self: *Signal, comptime handoff: bool) void {
        @setCold(true);

        // TODO: support FUTEX_SWAP in the future with handoff

        const rc = linux.futex_wake(
            @ptrCast(*const i32, &self.state),
            linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAKE,
            @as(i32, 1)
        );

        std.debug.assert(linux.getErrno(rc) == 0);
    }

    pub fn wait(self: *Signal) void {
        std.debug.assert(self.waitFast(null));
    }

    pub fn timedWait(self: *Signal, timeout: u64) error{TimedOut}!void {
        if (!self.waitFast(timeout))
            return error.TimedOut;
    }

    fn waitFast(self: *Signal, timeout: ?u64) bool {
        var state: State = .empty;
        while (true) {
            
            if (@cmpxchgWeak(
                State,
                &self.state,
                state,
                .waiting,
                .Acquire,
                .Acquire,
            )) |updated_state| {
                state = updated_state;
                switch (state) {
                    .empty => continue,
                    .waiting => std.debug.panic("multiple waiters on the same Signal", .{}),
                    .notified => {},
                }
            } else {
                state = .waiting;
            }
            
            if (state == .waiting and !self.waitSlow(timeout))
                return false;

            @atomicStore(State, &self.state, .empty, .Monotonic);
            return true;
        }
    }

    fn waitSlow(self: *Signal, timeout: ?u64) bool {
        @setCold(true);

        var ts: linux.timespec = undefined;
        var ts_ptr: ?*linux.timespec = null;

        var deadline: ?u64 = null;
        if (timeout) |timeout_ns|
            deadline = os_nanotime() + timeout_ns;
        
        while (true) {
            if (deadline) |deadline_ns| {
                const now = os_nanotime();

                if (now >= deadline_ns) {
                    return @cmpxchgStrong(
                        State,
                        &self.state,
                        .waiting,
                        .empty,
                        .Acquire,
                        .Acquire,
                    ) != null;
                }

                const wait_ns = deadline_ns - now;
                ts_ptr = &ts;
                ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), @mod(wait_ns, std.time.ns_per_s));
                ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), @divFloor(wait_ns, std.time.ns_per_s));
            }

            const rc = linux.futex_wait(
                @ptrCast(*const i32, &self.state),
                linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAIT,
                @enumToInt(State.waiting),
                ts_ptr,
            );

            switch (linux.getErrno(rc)) {
                0 => {},
                std.os.EINTR => {},
                std.os.EAGAIN => break,
                std.os.ETIMEDOUT => {},
                else => unreachable,
            }

            const state = @atomicLoad(State, &self.state, .Acquire);
            if (state != .waiting) {
                std.debug.assert(state == .notified);
                break;
            }
        }

        self.state = .waiting;
        return true;
    }

    pub fn yield(iter: usize) bool {
        return PosixSignal.yield(iter);
    }

    pub fn nanotime() u64 {
        return PosixSignal.nanotime();
    }
};

const PosixSignal = extern struct {
    const Waiter = struct {
        const State = enum {
            empty,
            waiting,
            notified,
        };

        state: State,
        cond: pthread_cond_t,
        mutex: pthread_mutex_t,

        fn init(self: *Waiter) !void {
            self.state = .empty;

            if (pthread_mutex_init(&self.mutex, null) != 0)
                return error.MutexInit;
            errdefer std.debug.assert(pthread_mutex_destroy(&self.mutex) == 0);

            var attr: pthread_condattr_t = undefined;
            if (pthread_condattr_init(&attr) != 0)
                return error.CondAttrInit;
            defer std.debug.assert(pthread_condattr_destroy(&attr) == 0);

            const target = std.Target.current;
            if (!(target.isDarwin() or target.isAndroid())) {
                if (pthread_condattr_setclock(&attr, std.os.CLOCK_MONOTONIC) != 0)
                    return error.CondSetClock;
            }

            if (pthread_cond_init(&self.cond, &attr) != 0)
                return error.CondInit;
        }

        fn deinit(self: *Waiter) void {
            std.debug.assert(pthread_cond_destroy(&self.cond) == 0);
            std.debug.assert(pthread_mutex_destroy(&self.mutex) == 0);
        }

        fn notify(self: *Waiter) void {
            std.debug.assert(pthread_mutex_lock(&self.mutex) == 0);
            defer std.debug.assert(pthread_mutex_unlock(&self.mutex) == 0);

            const state = self.state;
            self.state = .notified;

            switch (state) {
                .empty => {},
                .waiting => std.debug.assert(pthread_cond_signal(&self.cond) == 0),
                .notified => {},
            }
        }

        fn wait(self: *Waiter, timeout: ?u64) bool {
            std.debug.assert(pthread_mutex_lock(&self.mutex) == 0);
            defer std.debug.assert(pthread_mutex_unlock(&self.mutex) == 0);

            if (self.state == .waiting)
                std.debug.panic("multiple waiters on the same Signal", .{});

            if (self.state == .empty) {
                self.state = .waiting;

                var deadline: ?u64 = null;
                if (timeout) |timeout_ns|
                    deadline = timestamp() + timeout_ns;

                while (true) {
                    switch (self.state) {
                        .empty => std.debug.panic("waiter reset while waiting", .{}),
                        .waiting => {},
                        .notified => break,
                    }

                    const deadline_ns = deadline orelse {
                        std.debug.assert(pthread_cond_wait(&self.cond, &self.mutex) == 0);
                        continue;
                    };

                    const now = timestamp();
                    if (now >= deadline_ns) {
                        self.state = .empty;
                        return false;
                    }

                    const wait_ns = deadline_ns - now;
                    var ts: std.os.timespec = undefined;
                    ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), @mod(wait_ns, std.time.ns_per_s));
                    ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), @divFloor(wait_ns, std.time.ns_per_s));
                    
                    switch (pthread_cond_timedwait(&self.cond, &self.mutex, &ts)) {
                        0 => {},
                        std.os.ETIMEDOUT => {},
                        std.os.EINVAL => unreachable,
                        std.os.EPERM => unreachable,
                        else => unreachable,
                    }
                }
            }

            std.debug.assert(self.state == .notified);
            self.state = .empty;
            return true;
        }

        fn timestamp() u64 {
            if (comptime std.Target.current.isDarwin()) {
                var tv: std.os.timeval = undefined;
                std.debug.assert(std.c.gettimeofday(&tv, null) == 0);
                return (
                    (@intCast(u64, ts.tv_sec) * std.time.ns_per_s) + 
                    (@intCast(u64, ts.tv_usec) * std.time.us_per_s)
                );
            }

            const clock = switch (std.builtin.abi) {
                .android => std.os.CLOCK_REALTIME,
                else => std.os.CLOCK_MONOTONIC,
            };

            var ts: std.os.timespec = undefined;
            std.os.clock_gettime(clock, &ts) catch unreachable;
            return @intCast(u64, ts.tv_sec) * std.time.ns_per_s + @intCast(u64, ts.tv_nsec);
        }

        fn getCurrent() *Waiter {
            const key_ptr = getKeyPtr() orelse {
                std.debug.panic("pthread_key_create() failed", .{});
            };

            const ptr = pthread_getspecific(key_ptr.*);
            if (@ptrCast(?*Waiter, @alignCast(@alignOf(Waiter), ptr))) |self|
                return self;

            return getCurrentSlow(key_ptr);
        }

        fn getCurrentSlow(key_ptr: *pthread_key_t) *Waiter {
            @setCold(true);

            const self = constructor() catch {
                std.debug.panic("failed to allocate internal resources", .{});
            };

            const rc = pthread_setspecific(key_ptr.*, @ptrCast(*c_void, self));
            std.debug.assert(rc == 0);
            return self;
        }

        const allocator = std.heap.c_allocator;

        fn constructor() !*Waiter {
            const self = try allocator.create(Waiter);
            errdefer allocator.destroy(self);
            try self.init();
            return self;
        }

        fn destructor(waiter: *c_void) callconv(.C) void {
            const self = @ptrCast(*Waiter, @alignCast(@alignOf(Waiter), waiter));
            self.deinit();
            allocator.destroy(self);
        }

        var key: pthread_key_t = 0;
        var key_state = KeyState.uninit;

        const KeyState = enum(u8) {
            uninit,
            creating,
            init,
            failed,
        };

        fn getKeyPtr() ?*pthread_key_t {
            if (@atomicLoad(KeyState, &key_state, .Acquire) == .init)
                return &key;
            return getKeyPtrSlow();
        }

        fn getKeyPtrSlow() ?*pthread_key_t {
            @setCold(true);

            var iter: usize = 0;
            var state = @atomicLoad(KeyState, &key_state, .Acquire);
            while (true) {
                switch (state) {
                    .uninit => state = @cmpxchgWeak(
                        KeyState,
                        &key_state,
                        state,
                        .creating,
                        .Acquire,
                        .Acquire,
                    ) orelse {
                        state = switch (pthread_key_create(&key, destructor)) {
                            0 => .init,
                            else => .failed,
                        };
                        @atomicStore(KeyState, &key_state, state, .Release);
                        continue;
                    },
                    .creating => {
                        iter = if (!Signal.yield(iter)) 0 else (iter +% 1);
                        state = @atomicLoad(KeyState, &key_state, .Acquire);
                    },
                    .init => return &key,
                    .failed => return null,
                }
            }
        }
    };
    
    waiter: *Waiter = undefined,

    pub fn init(self: *Signal) void {
        self.waiter = Waiter.getCurrent();
    }

    pub fn deinit(self: *Signal) void {
        self.* = undefined;
    }

    pub inline fn notifyHandoff(self: *Signal) void {
        return self.waiter.notify();
    }

    pub fn notify(self: *Signal) void {
        return self.waiter.notify();
    }

    pub fn wait(self: *Signal) void {
        std.debug.assert(self.waiter.wait(null));
    }

    pub fn timedWait(self: *Signal, timeout: u64) error{TimedOut}!void {
        if (!self.waiter.wait(timeout))
            return error.TimedOut;
    }

    pub fn yield(iter: usize) bool {
        if (iter > 10)
            return false;

        if (iter <= 3) {
            spinLoopHint(iter);
        } else {
            std.os.sched_yield() catch unreachable;
        }

        return true;
    }

    pub fn nanotime() u64 {
        return os_nanotime();
    }

    const pthread_key_t = usize;
    const pthread_mutexattr_t = pthread_t;
    const pthread_condattr_t = pthread_t;
    const pthread_cond_t = pthread_t;
    const pthread_mutex_t = pthread_t;

    const pthread_t = extern struct {
        _opaque: [64]u8 align(16),
    };

    extern "c" fn pthread_key_create(key: *pthread_key_t, destructor: fn(*c_void) callconv(.C) void) callconv(.C) c_int;
    extern "c" fn pthread_setspecific(key: pthread_key_t, ptr: ?*c_void) callconv(.C) c_int;
    extern "c" fn pthread_getspecific(key: pthread_key_t) callconv(.C) ?*c_void;

    extern "c" fn pthread_condattr_init(attr: *pthread_condattr_t) callconv(.C) c_int;
    extern "c" fn pthread_condattr_setclock(attr: *pthread_condattr_t, clock: usize) callconv(.C) c_int;
    extern "c" fn pthread_condattr_destroy(attr: *pthread_condattr_t) callconv(.C) c_int;

    extern "c" fn pthread_cond_init(cond: *pthread_cond_t, attr: ?*const pthread_condattr_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_destroy(cond: *pthread_cond_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_wait(noalias cond: *pthread_cond_t, noalias mutex: *pthread_mutex_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_timedwait(noalias cond: *pthread_cond_t, noalias mutex: *pthread_mutex_t, noalias ts: *const std.os.timespec) callconv(.C) c_int;
    extern "c" fn pthread_cond_signal(cond: *pthread_cond_t) callconv(.C) c_int;

    extern "c" fn pthread_mutex_init(mutex: *pthread_mutex_t, attr: ?*const pthread_mutexattr_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_destroy(mutex: *pthread_mutex_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_lock(mutex: *pthread_mutex_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_unlock(mutex: *pthread_mutex_t) callconv(.C) c_int;
};