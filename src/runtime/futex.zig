const std = @import("std");
const zap = @import("../zap.zig");

const core = zap.core;
const system = std.os.system;
const Condition = core.sync.Condition;
const Atomic = core.sync.atomic.Atomic;

pub const Futex = extern struct {
    event: OsEvent = undefined,

    pub fn wait(self: *Futex, deadline: ?*Timestamp, condition: *Condition) bool {
        self.event.reset();

        if (condition.isMet())
            return true;

        return self.event.wait(if (deadline) |d| d.* else null);
    }

    pub fn wake(self: *Futex) void {
        self.event.set();
    }

    pub const Timestamp = u64;

    pub const nanotime = Clock.nanotime;

    pub fn timestamp(self: *Futex, current: *Timestamp) void {
        current.* = nanotime();
    }

    pub fn timeSince(self: *Futex, t1: *Timestamp, t2: *Timestamp) u64 {
        return t1.* - t2.*;
    }
};

const Clock = struct {
    var last_now: u64 = 0;
    var last_lock = core.sync.Lock{};

    fn nanotime() u64 {
        const now = OsEvent.nanotime();
        if (OsEvent.is_actually_monotonic)
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

        var last = @atomicLoad(u64, &last_now, .Monotonic);
        while (true) {
            if (last > now)
                return last;
            last = @cmpxchgWeak(
                u64,
                &last_now,
                last,
                now,
                .Monotonic,
                .Monotonic,
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

const OsEvent =
    if (core.is_windows)
        WindowsEvent
    else if (core.link_libc and core.is_posix)
        PosixEvent
    else if (core.is_linux)
        LinuxEvent
    else
        @compileError("OS thread blocking/unblocking not supported");


const LinuxEvent = AtomicEvent(struct {
    fn wait(ptr: *const i32, expected: i32, deadline: ?u64) i32 {
        var ts: system.timespec = undefined;
        var ts_ptr: ?*system.timespec = null;

        const atomic_ptr = @ptrCast(*const Atomic(i32), ptr);
        const futex_op = system.FUTEX_PRIVATE_FLAG | system.FUTEX_WAIT;

        while (true) {
            const value = atomic_ptr.load(.acquire);
            if (value != expected)
                return value;

            if (deadline) |deadline_ns| {
                const now = Clock.nanotime();
                if (now > deadline_ns)
                    return value;

                const duration = deadline_ns - now;
                ts_ptr = &ts;
                ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), @divFloor(duration, std.time.ns_per_s));
                ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), @mod(duration, std.time.ns_per_s));
            }

            const rc = system.futex_wait(ptr, futex_op, expected, ts_ptr);
            switch (system.getErrno(rc)) {
                0 => continue,
                system.EINTR => continue,
                system.EAGAIN => return atomic_ptr.load(.acquire),
                system.ETIMEDOUT => return value,
                else => @panic("futex(WAIT) unhandled errno code"),
            }
        }
    }

    fn wake(ptr: *const i32) void {
        const futex_op = system.FUTEX_PRIVATE_FLAG | system.FUTEX_WAKE;
        const rc = system.futex_wake(ptr, futex_op, @as(i32, 1));
        switch (rc) {
            0, 1, system.EFAULT => {},
            else => @panic("futex(WAKE) unhandled errno"),
        }
    }

    fn cancel(ptr: *const i32) void {}

    const nanotime = PosixEvent.nanotime;
    const is_actually_monotonic = switch (core.os_type) {
        .linux => core.arch_type != .aarch64 and .arch_type != .s390x,
        .openbsd => core.arch_type != .x86_64,
        else => true,
    };
});

const WindowsEvent = AtomicEvent(struct {
    fn wait(ptr: *const i32, expected: i32, deadline: ?u64) i32 {
        var timed_out = false;
        var timeout: system.LARGE_INTEGER = undefined;
        var timeout_ptr: ?*system.LARGE_INTEGER = null;

        if (deadline) |deadline_ns| {
            const now = Clock.nanotime();
            timed_out = now > deadline_ns;

            if (!timed_out) {
                timeout_ptr = &timeout;
                timeout = @intCast(@TypeOf(timeout), deadline_ns - now);
                timeout = -(@divFloor(timeout, 100));
            }
        }

        if (!timed_out) {
            const key = @ptrCast(*align(4) const c_void, ptr);
            switch (NtWaitForKeyedEvent(null, key, system.FALSE, timeout_ptr)) {
                .SUCCESS => {},
                .TIMEOUT => {},
                else => @panic("NtWaitForKeyedEvent unknown status"),
            }
        }

        const atomic_ptr = @ptrCast(*const Atomic(i32), ptr); 
        return atomic_ptr.load(.acquire);
    }

    fn wake(ptr: *const i32) void {
        const key = @ptrCast(*align(4) const c_void, ptr);
        switch (NtReleaseKeyedEvent(null, key, system.FALSE, null)) {
            .SUCCESS => {},
            else => @panic("NtReleaseKeyedEvent unknown status"),
        }
    }

    fn cancel(ptr: *const i32) void {
        const key = @ptrCast(*align(4) const c_void, ptr);
        switch (NtWaitForKeyedEvent(null, key, system.FALSE, null)) {
            .SUCCESS => {},
            else => @panic("NtWaitForKeyedEvent in cancel with unknown status"),
        }
    }

    const is_actually_monotonic = false;

    fn nanotime() u64 {
        const frequency = Clock.getCachedFrequency(system.QueryPerformanceFrequency);
        const counter = system.QueryPerformanceCounter();
        return @divFloor(counter *% std.time.ns_per_s, frequency);
    }

    extern "NtDll" fn NtWaitForKeyedEvent(
        handle: ?system.HANDLE,
        key: ?*align(4) const c_void,
        alertable: system.BOOLEAN,
        timeout: ?*const system.LARGE_INTEGER,
    ) callconv(.Stdcall) system.NTSTATUS;

    extern "NtDll" fn NtReleaseKeyedEvent(
        handle: ?system.HANDLE,
        key: ?*align(4) const c_void,
        alertable: system.BOOLEAN,
        timeout: ?*const system.LARGE_INTEGER,
    ) callconv(.Stdcall) system.NTSTATUS;
});

fn AtomicEvent(comptime FutexImpl: type) type {
    return extern struct {
        state: Atomic(State) = undefined,

        const Self = @This();
        const State = extern enum(i32) {
            running,
            waiting,
        };

        fn reset(self: *Self) void {
            self.state.set(.waiting);
        }

        fn wait(self: *Self, deadline: ?u64) bool {
            var state = @intToEnum(State, FutexImpl.wait(
                @ptrCast(*const i32, &self.state),
                @as(i32, @enumToInt(State.waiting)),
                deadline,
            ));

            if (state == .running)
                return true;

            state = self.state.swap(.running, .acquire);
            if (state == .running)
                FutexImpl.cancel(@ptrCast(*const i32, &self.state));

            return false;
        }

        fn set(self: *Self) void {
            if (self.state.swap(.running, .release) == .waiting) {
                FutexImpl.wake(@ptrCast(*const i32, &self.state));
            }
        }

        const nanotime = FutexImpl.nanotime;
        const is_actually_monotonic = FutexImpl.is_actually_monotonic;
    };
}

const PosixEvent = extern struct {

    const is_actually_monotonic = 
        if (core.is_linux) LinuxEvent.is_actually_monotonic
        else true;

    fn nanotime() u64 {
        if (core.is_darwin) {
            const frequency = Clock.getCachedFrequency(struct {
                fn get() system.mach_timebase_info_data {
                    var info: @TypeOf(@This().get()) = undefined;
                    system.mach_timebase_info(&info);
                    return info;
                }
            }.get);
            const counter = system.mach_absolute_time();
            return @divFloor(counter *% frequency.numer, frequency.denom);
        }
        
        var ts: system.timespec = undefined;
        const rc = system.clock_gettime(system.CLOCK_MONOTONIC, &ts);
        if (system.getErrno(rc) != 0)
            @panic("clock_gettime(CLOCK_MONOTONIC) unhandled errno");
        return (@intCast(u64, ts.tv_sec) * std.time.ns_per_s) + @intCast(u64, ts.tv_nsec);
    }
};