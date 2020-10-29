const std = @import("std");
const zap = @import("./zap.zig");
const system = std.os.system;

pub const Signal = struct {
    event: OsEvent,

    pub fn init(self: *Signal) void {
        self.event.init();
    }

    pub fn deinit(self: *Signal) void {
        self.event.deinit();
    }

    pub fn wait(self: *Signal) void {
        self.event.waitUntil(null) catch unreachable;
    }

    pub fn waitFor(self: *Signal, duration: u64) error{TimedOut}!void {
        if (duration == 0)
            return error.TimedOut;
        return self.event.waitUntil(Signal.nanotime() + duration);
    }

    pub fn waitUntil(self: *Signal, deadline: u64) error{TimedOut}!void {
        return self.event.waitUntil(deadline);
    }

    pub fn notify(self: *Signal) void {
        self.event.notify();
    }

    var last_now: u64 = 0;
    var last_lock = zap.sync.os.Lock{};

    pub fn timestamp(self: *Signal) u64 {
        return nanotime();
    }

    fn nanotime() u64 {
        const now = OsEvent.nanotime();
        if (OsEvent.is_actually_monotonic)
            return now;

        if (std.meta.bitCount(usize) < 64) {
            last_lock.acquire();
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
};

const OsEvent = 
    if (std.builtin.os.tag == .windows) 
        NtKeyedEvent
    else if (std.builtin.link_libc and is_posix)
        PthreadEvent
    else if (std.builtin.os.tag == .linux)
        FutexEvent
    else
        @compileError("OS event blocking primitive not supported");

const is_posix = switch (std.builtin.os.tag) {
    .linux,
    .minix,
    .macos,
    .ios,
    .tvos,
    .watchos,
    .openbsd,
    .freebsd,
    .kfreebsd,
    .netbsd,
    .dragonfly => true,
    else => false,
};

fn ReturnTypeOf(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).Fn.return_type.?;
}

fn cached(comptime generateFn: anytype) ReturnTypeOf(generateFn) {
    const Value = ReturnTypeOf(generateFn);
    const State = enum(usize) {
        uninit,
        storing,
        init,
    };

    const Cache = struct {
        var state: State = .uninit;
        var value: Value = undefined;
        
        fn get() Value {
            if (@atomicLoad(State, &state, .Acquire) == .init)
                return value;
            return getSlow();
        }

        fn getSlow() Value {
            @setCold(true);

            const local = generateFn();
            if (@cmpxchgStrong(
                State,
                &state,
                .uninit,
                .storing,
                .Monotonic,
                .Monotonic,
            ) == null) {
                value = local;
                @atomicStore(State, &state, .init, .Release);
            }

            return local;
        }
    };

    return Cache.get();
}

const FutexEvent = AtomicEvent(struct {

});

const NtKeyedEvent = AtomicEvent(struct {
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

    fn wait(ptr: *const i32, expected: i32, deadline: ?u64) i32 {
        var timed_out = false;
        var timeout: system.LARGE_INTEGER = undefined;
        var timeout_ptr: ?*system.LARGE_INTEGER = null;

        if (deadline) |deadline_ns| {
            const now = Signal.nanotime();
            timed_out = now > deadline_ns;

            if (!timed_out) {
                timeout_ptr = &timeout;
                timeout = @intCast(@TypeOf(timeout), deadline_ns - now);
                timeout = -(@divFloor(timeout, 100));
            }
        }

        if (!timed_out) {
            const key = @ptrCast(*align(4) const c_void, ptr);
            const status = NtWaitForKeyedEvent(null, key, system.FALSE, timeout_ptr);
            switch (status) {
                .SUCCESS => {},
                .TIMEOUT => {},
                else => @panic("NtWaitForKeyedEvent unknown status"),
            }
        }

        const state = @atomicLoad(i32, ptr, .Acquire);
        return state;
    }

    fn wake(ptr: *const i32) void {
        const key = @ptrCast(*align(4) const c_void, ptr);
        const status = NtReleaseKeyedEvent(null, key, system.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    fn cancel(ptr: *const i32) void {
        const key = @ptrCast(*align(4) const c_void, ptr);
        const status = NtWaitForKeyedEvent(null, key, system.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    const is_actually_monotonic = false;

    fn nanotime() u64 {
        const frequency = cached(system.QueryPerformanceFrequency);
        const counter = system.QueryPerformanceCounter();
        return @divFloor(counter * std.time.ns_per_s, frequency);
    }
});

fn AtomicEvent(comptime Futex: type) type {
    return struct {
        state: State = .empty,

        const Self = @This();
        const State = enum(i32) {
            empty,
            waiting,
            notified,
        };

        fn init(self: *Self) void {
            self.* = Self{};
        }

        fn deinit(self: *Self) void {
            self.* = undefined;
        }

        fn waitUntil(self: *Self, deadline: ?u64) error{TimedOut}!void {
            var state = switch (@atomicRmw(State, &self.state, .Xchg, .waiting, .Acquire)) {
                .empty => @intToEnum(State, Futex.wait(
                    @ptrCast(*const i32, &self.state),
                    @as(i32, @enumToInt(State.waiting)),
                    deadline,
                )),
                .waiting => @panic("OsEvent being waited on by multiple threads"),
                .notified => State.notified,
            };

            state = switch (state) {
                .empty => @panic("OsEvent timing out with invalid state"),
                .waiting => @cmpxchgStrong(
                    State,
                    &self.state,
                    state,
                    .empty,
                    .Acquire,
                    .Acquire,
                ) orelse return error.TimedOut,
                .notified => {
                    self.state = .empty;
                    return;
                },
            };

            if (state != .notified)
                @panic("OsEvent timing out failed with invalid state");
            Futex.cancel(@ptrCast(*const i32, &self.state));
            self.state = .empty;
        }

        fn notify(self: *Self) void {
            switch (@atomicRmw(State, &self.state, .Xchg, .notified, .Release)) {
                .empty => {},
                .waiting => Futex.wake(@ptrCast(*const i32, &self.state)),
                .notified => @panic("OsEvent was notified multiple times"),
            }
        }

        pub const is_actually_monotonic = Futex.is_actually_monotonic;
        pub const nanotime = Futex.nanotime;
    };
}

const PthreadEvent = struct {

};
