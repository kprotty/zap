const std = @import("std");

pub const AutoResetEvent =
    if (std.builtin.os.tag == .windows) WindowsEvent
    else if (std.builtin.link_libc) PosixEvent
    else if (std.builtin.os.tag == .linux) LinuxEvent
    else @compileError("Operating System not supported");

const LinuxEvent = FutexEvent(struct {
    const linux = std.os.linux;

    fn wake(ptr: *const u32) void {
        const key = @ptrCast(*const i32, ptr);
        const rc = linux.futex_wake(key, linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG, 1);
        std.debug.assert(linux.getErrno(rc) == 0);
    }

    fn wait(ptr: *u32, expect: u32, reset: u32, deadline: ?u64) bool {
        const key = @ptrCast(*const i32, ptr);
        const expected = @bitCast(i32, expect);
        var ts: linux.timespec = undefined;
        var ts_ptr: ?*linux.timespec = null;

        while (@atomicLoad(u32, ptr, .Acquire) == expected) {
            if (deadline) |deadline_ns| {
                const now = nanotime();
                if (now >= deadline_ns) {
                    _ = @cmpxchgStrong(u32, ptr, expect, reset, .Acquire, .Acquire) orelse return false;
                    return true;
                }

                const timeout_ns = deadline_ns - now;
                ts_ptr = &ts;
                ts.tv_sec = @intCast(isize, timeout_ns / std.time.ns_per_s);
                ts.tv_nsec = @intCast(isize, timeout_ns % std.time.ns_per_s);
            }

            const rc = linux.futex_wait(key, linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG, expected, ts_ptr);
            switch (linux.getErrno(rc)) {
                0, linux.ETIMEDOUT, linux.EINTR, linux.EAGAIN => {},
                else => unreachable,
            }
        }

        return true;
    }

    threadlocal var last_now: u64 = 0;

    fn nanotime() u64 {
        var ts: linux.timespec = undefined;
        const rc = linux.clock_gettime(linux.CLOCK_MONOTONIC, &ts);
        std.debug.assert(linux.getErrno(rc) == 0);
        var now = @intCast(u64, ts.tv_sec) * @as(u64, std.time.ns_per_s) + @intCast(u64, ts.tv_nsec);

        if (std.builtin.arch == .aarch64 or .arch == .s390x) {
            if (now < last_now) {
                now = last_now;
            } else {
                last_now = now;
            }
        }

        return now;
    }
});

const WindowsEvent = FutexEvent(struct {
    const windows = std.os.windows;

    fn wake(ptr: *const u32) void {
        @setCold(true);

        const handle = getEventHandle() orelse return;
        const key = @ptrCast(*const c_void, ptr);
        const status = windows.ntdll.NtReleaseKeyedEvent(handle, key, windows.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    fn wait(ptr: *u32, expected: u32, reset: u32, deadline: ?u64) bool {
        @setCold(true);

        const handle = getEventHandle() orelse {
            var spin: usize = 0;
            while (@atomicLoad(u32, ptr, .Acquire) == expected) {
                if (FutexEvent(struct{}).yield(false, spin)) {
                    spin +%= 1;
                } else {
                    spin = 0;
                }
            }
            return true;
        };
        
        var timeout_ptr: ?*windows.LARGE_INTEGER = null;
        var timeout: windows.LARGE_INTEGER = undefined;
        if (deadline) |deadline_ns| {
            const now = nanotime();
            if (now >= deadline_ns)
                return false;
            timeout = @intCast(windows.LARGE_INTEGER, deadline_ns / 100);
            timeout = -timeout;
            timeout_ptr = &timeout;
        }

        const key = @ptrCast(*const c_void, ptr);
        var status = windows.ntdll.NtWaitForKeyedEvent(handle, key, windows.FALSE, timeout_ptr);
        switch (status) {
            .TIMEOUT => {
                _ = @cmpxchgStrong(u32, ptr, expected, reset, .Acquire, .Acquire) orelse return false;
                status = windows.ntdll.NtWaitForKeyedEvent(handle, key, windows.FALSE, null);
                std.debug.assert(status == .WAIT_0);
                return true;
            },
            .WAIT_0 => return true,
            else => unreachable,
        }
    }

    var event_handle: usize = EMPTY;
    const EMPTY = ~@as(usize, 0);
    const LOADING = EMPTY - 1;

    fn getEventHandle() ?windows.HANDLE {
        var handle = @atomicLoad(usize, &event_handle, .Acquire);
        while (true) {
            switch (handle) {
                EMPTY => handle = @cmpxchgWeak(usize, &event_handle, EMPTY, LOADING, .Acquire, .Monotonic) orelse {
                    const handle_ptr = @ptrCast(*windows.HANDLE, &handle);
                    const access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE;
                    if (windows.ntdll.NtCreateKeyedEvent(handle_ptr, access_mask, null, 0) != .SUCCESS)
                        handle = 0;
                    @atomicStore(usize, &event_handle, handle, .Release);
                    return @intToPtr(?windows.HANDLE, handle);
                },
                LOADING => {
                    windows.kernel32.Sleep(0);
                    handle = @atomicLoad(usize, &event_handle, .Acquire);
                },
                else => {
                    return @intToPtr(?windows.HANDLE, handle);
                },
            }
        }
    }

    const FreqState = enum(usize) {
        Empty,
        Updating,
        Created,
    };

    var freq_state: FreqState = FreqState.Empty;
    var frequency: u64 = undefined;
    threadlocal var last_now: u64 = 0;

    fn nanotime() u64 {
        const freq = blk: {
            if (@atomicLoad(FreqState, &freq_state, .Acquire) == .Created)
                break :blk frequency;
            var f = windows.QueryPerformanceFrequency();
            if (@cmpxchgStrong(FreqState, &freq_state, .Empty, .Updating, .Acquire, .Acquire) == null) {
                frequency = f;
                @atomicStore(FreqState, &freq_state, .Created, .Release);
            }
            break :blk f;
        };
        
        const counter = windows.QueryPerformanceCounter();
        var now = @divFloor(counter * std.time.ns_per_s, freq);
        if (now < last_now) {
            now = last_now;
        } else {
            last_now = now;
        }

        return now;
    }
});

fn FutexEvent(comptime Futex: type) type {
    const State = extern enum(u32) {
        Empty,
        Waiting,
        Notified,
    };

    return extern struct {
        const Self = @This();

        state: State = State.Empty,

        pub fn init(self: *Self) void {
            self.* = .{};
        }

        pub fn deinit(self: *Self) void {
            defer self.* = undefined;

            if (std.debug.runtime_safety) {
                if (@atomicLoad(State, &self.state, .Monotonic) == .Waiting)
                    std.debug.panic("system.AutoResetEvent.deinit(): pending waiter", .{});
            }
        }

        pub fn set(self: *Self, direct_yield: bool) void {
            var state = @atomicLoad(State, &self.state, .Monotonic);

            if (state == .Empty) {
                state = @cmpxchgStrong(
                    State,
                    &self.state,
                    .Empty,
                    .Notified,
                    .Release,
                    .Monotonic,
                ) orelse return;
            }

            if (state == .Notified)
                return;
            
            @atomicStore(State, &self.state, .Empty, .Release);
            return Futex.wake(@intToPtr(*const u32, @ptrToInt(&self.state)));
        }

        pub fn wait(self: *Self) void {
            self.tryWait(null) catch unreachable;
        }

        pub fn tryWaitUntil(self: *Self, deadline: u64) error{TimedOut}!void {
            return self.tryWait(deadline);
        }

        fn tryWait(self: *AutoResetEvent, deadline: ?u64) error{TimedOut}!void {
            var state = @atomicLoad(State, &self.state, .Acquire);

            if (state == .Empty) {
                var spin: usize = 0;
                while (yield(false, spin)) : (spin += 1) {
                    state = @atomicLoad(State, &self.state, .Acquire);
                    if (state != .Empty)
                        break;
                }
            }

            if (state == .Empty) {
                state = @cmpxchgStrong(
                    State,
                    &self.state,
                    .Empty,
                    .Waiting,
                    .Acquire,
                    .Acquire,
                ) orelse {
                    if (!Futex.wait(
                        @ptrCast(*u32, &self.state),
                        @enumToInt(State.Waiting),
                        @enumToInt(State.Empty),
                        deadline,
                    )) return error.TimedOut;
                    return;
                };
            }

            std.debug.assert(state == .Notified);
            @atomicStore(State, &self.state, .Empty, .Monotonic);
        }

        pub fn nanotime() u64 {
            return Futex.nanotime();
        }

        pub fn yield(contended: bool, iteration: usize) bool {
            if (contended or iteration > 6)
                return false;

            var spin: usize = @as(usize, 1) << @intCast(std.math.Log2Int(usize), iteration);
            while (spin != 0) : (spin -= 1) {
                switch (std.builtin.arch) {
                    .i386, .x86_64 => asm volatile("pause" ::: "memory"),
                    .arm, .aarch64 => asm volatile("yield" ::: "memory"),
                    else => @fence(.SeqCst),
                }
            }

            return true;
        }
    };
}

const PosixEvent = extern struct {
    const EMPTY = 0x0;
    const NOTIFIED = 0x1;

    state: usize = EMPTY,

    pub fn init(self: *PosixEvent) void {
        self.* = .{};
    }

    pub fn deinit(self: *PosixEvent) void {
        defer self.* = undefined;

        if (std.debug.runtime_safety) {
            const state = @atomicLoad(usize, &self.state, .Monotonic);
            if (!(state == EMPTY or state == NOTIFIED))
                std.debug.panic("system.AutoResetEvent.deinit() pending waiter\n", .{});
        }
    }

    pub fn set(self: *PosixEvent, direct_yield: bool) void {
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        if (state == EMPTY) {
            state = @cmpxchgStrong(
                usize,
                &self.state,
                EMPTY,
                NOTIFIED,
                .Release,
                .Monotonic,
            ) orelse return;
        }

        if (state == NOTIFIED)
            return;
        
        @atomicStore(usize, &self.state, EMPTY, .Release);
        return @intToPtr(*Event, state).notify();
    }

    pub fn wait(self: *PosixEvent) void {
        self.tryWait(null) catch unreachable;
    }

    pub fn tryWaitUntil(self: *PosixEvent, deadline: u64) error{TimedOut}!void {
        return self.tryWait(deadline);
    }

    fn tryWait(self: *PosixEvent, deadline: ?u64) error{TimedOut}!void {
        var state = @atomicLoad(usize, &self.state, .Acquire);

        if (state == EMPTY) {
            var has_stack_event = false;
            var stack_event: Event = undefined;
            var event_ptr: *Event = undefined;
            defer if (has_stack_event)
                stack_event.deinit();

            if (!Event.get(&event_ptr)) {
                has_stack_event = true;
                stack_event.init();
                event_ptr = &stack_event;
            }

            state = @cmpxchgStrong(
                usize,
                &self.state,
                EMPTY,
                @ptrToInt(event_ptr),
                .Acquire,
                .Acquire,
            ) orelse {
                if (!event_ptr.wait(deadline))
                    return error.TimedOut;
                return;
            };
        }

        std.debug.assert(state == NOTIFIED);
        @atomicStore(usize, &self.state, EMPTY, .Monotonic);
    }

    pub fn yield(contended: bool, iteration: usize) bool {
        return FutexEvent(struct {}).yield(contended, iteration);
    }

    threadlocal var last_now: u64 = 0;
    var freq_state: FreqState = FreqState.Uninit;
    var frequency: std.os.darwin.mach_timebase_info_data = undefined;

    const FreqState = enum(usize) {
        Uninit,
        Updating,
        Created,
    };

    pub fn nanotime() u64 {
        if (comptime std.Target.current.isDarwin()) {
            const freq = blk: {
                if (@atomicLoad(FreqState, &freq_state, .Acquire) == .Created)
                    break :blk frequency;
                var f: @TypeOf(frequency) = undefined;
                std.os.darwin.mach_timebase_info(&f);
                if (@cmpxchgStrong(FreqState, &freq_state, .Uninit, .Updating, .Monotonic, .Monotonic) == null) {
                    frequency = f;
                    @atomicStore(FreqState, &freq_state, .Created, .Release);
                }
                return f;
            };
            const now = std.os.darwin.mach_absolute_time();
            return @divFloor(now * freq.numer, freq.denom);
        }

        var ts: std.os.timespec = undefined;
        const rc = std.os.clock_gettime(std.os.CLOCK_MONOTONIC, &ts) catch unreachable;
        var now = @intCast(u64, ts.tv_sec) * @as(u64, std.time.ns_per_s) + @intCast(u64, ts.tv_nsec);

        const is_actually_monotonic = !(switch (std.builtin.os.tag) {
            .openbsd => std.builtin.arch == .x86_64,
            .linux => std.builtin.arch == .aarch64 or .arch == .s390x,
            else => false,
        });

        if (!is_actually_monotonic) {
            if (now < last_now) {
                now = last_now;
            } else {
                last_now = now;
            }
        }

        return now;
    }

    const Event = extern struct {
        const EventState = extern enum(usize) {
            Empty,
            Waiting,
            Notified,
        };
    
        const pthread_key_t = switch (std.builtin.os.tag) {
            .cloudabi, .hermit => usize,
            .fuchsia, .emscripten, .solaris => c_uint,
            .haiku, .openbsd, .netbsd, .freebsd, .dragonfly => c_int,
            .linux => if (comptime std.Target.current.isAndroid()) c_int else c_uint,
            else => if (comptime std.Target.current.isDarwin()) c_ulong else usize,
        };

        extern "c" fn pthread_getspecific(k: pthread_key_t) callconv(.C) ?*c_void;
        extern "c" fn pthread_setspecific(k: pthread_key_t, v: *c_void) callconv(.C) c_int;
        extern "c" fn pthread_key_delete(k: pthread_key_t) callconv(.C) c_int;
        extern "c" fn pthread_key_create(
            k: *pthread_key_t,
            dtor: ?fn(*c_void) callconv(.C) void,
        ) callconv(.C) c_int;

        const pthread_condattr_t = u128;
        extern "c" fn pthread_condattr_init(c: *pthread_condattr_t) callconv(.C) c_int;
        extern "c" fn pthread_condattr_destroy(c: *pthread_condattr_t) callconv(.C) c_int;
        extern "c" fn pthread_condattr_setclock(c: *pthread_condattr_t, clock: usize) callconv(.C) c_int;
        extern "c" fn pthread_cond_init(noalias cond: *std.c.pthread_cond_t, noalias attr: *pthread_condattr_t) callconv(.C) c_int;

        state: EventState,
        _padding1: [128 - @sizeOf(usize)]u8,
        cond: std.c.pthread_cond_t,
        _padding2: [128 - @sizeOf(std.c.pthread_cond_t)]u8,
        mutex: std.c.pthread_mutex_t,

        const KeyState = enum(usize) {
            Uninit,
            Waiting,
            Created,
            Error,
        };

        var key_state: KeyState = KeyState.Uninit;
        var tls_key: pthread_key_t = undefined;

        fn alloc() ?*c_void {
            const ptr = std.c.malloc(@sizeOf(Event)) orelse return null;
            const event_ptr = @ptrCast(*Event, @alignCast(@alignOf(*Event), ptr));
            event_ptr.init();
            return ptr;
        }

        fn free(ptr: *c_void) callconv(.C) void {
            const event_ptr = @ptrCast(*Event, @alignCast(@alignOf(*Event), ptr));
            event_ptr.deinit();
            std.c.free(ptr);
        }

        fn get(ptr: **Event) bool {
            var state = @atomicLoad(KeyState, &key_state, .Acquire);
            while (true) {
                switch (state) {
                    .Uninit => state = @cmpxchgWeak(KeyState, &key_state, .Uninit, .Waiting, .Acquire, .Acquire) orelse {
                        state = .Error;
                        if (pthread_key_create(&tls_key, Event.free) == 0) {
                            if (Event.alloc()) |event_ptr| {
                                state = .Created;
                                ptr.* = @ptrCast(*Event, @alignCast(@alignOf(*Event), event_ptr));
                                std.debug.assert(pthread_setspecific(tls_key, event_ptr) == 0);
                            }
                        }
                        @atomicStore(KeyState, &key_state, state, .Release);
                        return state == .Created;
                    },
                    .Waiting => {
                        std.os.sched_yield() catch unreachable;
                        state = @atomicLoad(KeyState, &key_state, .Acquire);
                    },
                    .Created => {
                        const event_ptr = pthread_getspecific(tls_key);
                        ptr.* = @ptrCast(*Event, @alignCast(@alignOf(*Event), event_ptr));
                        return true;
                    },
                    .Error => {
                        return false;
                    },
                }
            }
        }
        
        fn init(self: *Event) void {
            self.state = .Empty;
            self.mutex = std.c.PTHREAD_MUTEX_INITIALIZER;

            if (
                (comptime std.Target.current.isDarwin()) or
                (comptime std.Target.current.isAndroid())
            ) {
                self.cond = std.c.PTHREAD_COND_INITIALIZER;
            } else {
                var attr: pthread_condattr_t = undefined;
                std.debug.assert(pthread_condattr_init(&attr) == 0);
                defer std.debug.assert(pthread_condattr_destroy(&attr) == 0);
                std.debug.assert(pthread_condattr_setclock(&attr, std.os.CLOCK_MONOTONIC) == 0);
                std.debug.assert(pthread_cond_init(&self.cond, &attr) == 0);
            }
        }

        fn deinit(self: *Event) void {
            const err = if (std.builtin.os.tag == .dragonfly) std.os.EAGAIN else 0;

            var rc = std.c.pthread_mutex_destroy(&self.mutex);
            std.debug.assert(rc == 0 or rc == err);

            rc = std.c.pthread_cond_destroy(&self.cond);
            std.debug.assert(rc == 0 or rc == err);
        }

        fn notify(self: *Event) void {
            std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
            defer std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

            switch (self.state) {
                .Empty => self.state = .Notified,
                .Waiting => {
                    self.state = .Empty;
                    std.debug.assert(std.c.pthread_cond_signal(&self.cond) == 0);
                },
                .Notified => {},
            }
        }

        fn wait(self: *Event, deadline: ?u64) bool {
            std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
            defer std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

            switch (self.state) {
                .Empty => self.state = .Waiting,
                .Waiting => unreachable,
                .Notified => {
                    self.state = .Empty;
                    return true;
                },
            }

            while (self.state == .Waiting) {
                var ts: std.os.timespec = undefined;
                if (deadline) |deadline_ns| {
                    const now = nanotime();
                    if (now >= deadline_ns)
                        return false;

                    var ts_now: u64 = 0;
                    if (comptime std.Target.current.isDarwin()) {
                        var tv: std.os.darwin.timeval = undefined;
                        std.debug.assert(std.os.darwin.gettimeofday(&tv, null) == 0);
                        ts_now = @intCast(u64, tv.tv_sec) * std.time.second;
                        ts_now += @intCast(u64, tv.tv_usec) * std.time.microsecond;
                    } else if (comptime std.Target.current.isAndroid()) {
                        std.os.clock_gettime(std.os.CLOCK_REALTIME, &ts);
                        ts_now = @intCast(u64, ts.tv_nsec);
                        ts_now += @intCast(u64, ts.tv_sec) * std.time.second;
                    }

                    ts_now += deadline_ns - now;
                    ts.tv_sec = @intCast(isize, ts_now / std.time.second);
                    ts.tv_nsec = @intCast(isize, ts_now % std.time.second);
                }

                const rc = switch (deadline == null) {
                    true => std.c.pthread_cond_wait(&self.cond, &self.mutex),
                    else => std.c.pthread_cond_timedwait(&self.cond, &self.mutex, &ts),
                };
                switch (rc) {
                    0, std.os.ETIMEDOUT, std.os.EINVAL, std.os.EPERM => {},
                    else => unreachable,
                }
            }

            return true;
        }
    };
};
