const std = @import("std");
const zap = @import("../../zap.zig");

const core = zap.core;
const Futex = zap.runtime.sync.Futex;
const Atomic = core.sync.atomic.Atomic;
const LinuxEvent = @import("../linux/event.zig").Event;

pub const Event = extern struct {
    binary_semaphore: ?*BinarySemaphore = null,

    pub fn prepare(self: *Event) void {
        if (self.binary_semaphore == null)
            self.binary_semaphore = BinarySemaphore.get();
    }

    pub fn wait(self: *Event, deadline: ?u64) bool {
        return self.binary_semaphore.?.wait(deadline);   
    }

    pub fn notify(self: *Event) void {
        return self.binary_semaphore.?.notify();
    }

    pub fn yield() void {
        if (core.is_linux)
            return LinuxEvent.yield();
        _ = sched_yield();
    }

    pub const is_monotonic = 
        if (core.is_linux) LinuxEvent.is_monotonic
        else if (core.os_tag == .openbsd and core.arch_tag == .x86_64) false
        else true;

    pub fn nanotime() u64 {
        if (core.is_darwin)
            return nanotimeDarwin();

        var ts: std.os.timespec = undefined;
        std.os.clock_gettime(std.os.CLOCK_MONOTONIC, &ts) catch unreachable;

        const ns = @intCast(u64, ts.tv_sec) * @as(u64, std.time.ns_per_s);
        return ns + @intCast(u64, ts.tv_nsec);
    }

    fn nanotimeDarwin() u64 {
        const darwin = std.os.darwin;

        const Frequency = struct {
            var frequency_state = Atomic(State).init(.uninit);
            var frequency: darwin.mach_timebase_info_data = undefined;

            const State = enum(u8) {
                uninit,
                storing,
                init,
            };

            fn get() @TypeOf(frequency) {
                if (frequency_state.load(.acquire) == .init)
                    return frequency;
                return getSlow();
            }

            fn getSlow() @TypeOf(frequency) {
                @setCold(true);

                var freq: @TypeOf(frequency) = undefined;
                darwin.mach_timebase_info(&freq);

                _ = frequency_state.compareAndSwap(
                    .uninit,
                    .init,
                    .relaxed,
                    .relaxed,
                ) orelse {
                    frequency = freq;
                    frequency_state.store(.init, .release);
                    return freq;
                };

                return freq;
            }
        };

        const frequency = Frequency.get();
        const counter = darwin.mach_absolute_time();
        return @divFloor(counter *% frequency.numer, frequency.denom);
    }
};

const BinarySemaphore = extern struct {
    updated: bool,
    cond: pthread_cond_t,
    mutex: pthread_mutex_t,

    var key_state = Atomic(KeyState).init(.uninit);
    var tls_key: pthread_key_t = undefined;

    const KeyState = enum(usize) {
        uninit,
        creating,
        init,
        failed,
    };

    fn getKey() pthread_key_t {
        if (key_state.load(.acquire) == .init)
            return tls_key;
        return getKeySlow();
    }

    fn getKeySlow() pthread_key_t {
        var state = key_state.load(.acquire);
        while (true) {
            switch (state) {
                .uninit => {
                    state = key_state.tryCompareAndSwap(
                        .uninit,
                        .init,
                        .acquire,
                        .acquire,
                    ) orelse blk: {
                        state = .init;
                        if (pthread_key_create(&tls_key, destructor) != 0)
                            state = .failed;
                        key_state.store(state, .release);
                        break :blk state;
                    };
                },
                .creating => {
                    Event.yield();
                    state = key_state.load(.acquire);
                },
                .init => {
                    return tls_key;
                },
                .failed => {
                    unreachable; // failed to allocate pthread_key_T
                },
            }
        }
    }

    fn constructor() !*BinarySemaphore {
        const ptr = malloc(@sizeOf(BinarySemaphore)) orelse return error.OutOfMemory;
        errdefer free(ptr);

        const self = @ptrCast(*BinarySemaphore, @alignCast(@alignOf(BinarySemaphore), ptr));
        self.updated = false;

        if (pthread_cond_init(&self.cond, null) != 0)
            return error.CondInit;
        errdefer std.debug.assert(pthread_cond_destroy(&self.cond) == 0);

        if (pthread_mutex_init(&self.mutex, null) != 0)
            return error.MutexInit;
        errdefer std.debug.assert(pthread_mutex_destroy(&self.mutex) == 0);

        return self;
    }

    fn destructor(ptr: *c_void) callconv(.C) void {
        const self = @ptrCast(*BinarySemaphore, @alignCast(@alignOf(BinarySemaphore), ptr));
        defer free(ptr);
        
        std.debug.assert(pthread_cond_destroy(&self.cond) == 0);
        std.debug.assert(pthread_mutex_destroy(&self.mutex) == 0);
    }

    fn get() *BinarySemaphore {
        const key = getKey();
        
        var key_ptr = pthread_getspecific(key);
        if (@ptrCast(?*BinarySemaphore, @alignCast(@alignOf(BinarySemaphore), key_ptr))) |self|
            return self;

        const ptr = constructor() catch unreachable; // failed to create a pthread BinarySemaphore
        if (pthread_setspecific(key, @ptrCast(*c_void, ptr)) != 0)
            unreachable; // failed to set pthread BinarySemaphore to thread-local-storage

        return ptr;
    }

    fn acquire(self: *BinarySemaphore) void {
        if (pthread_mutex_lock(&self.mutex) != 0)
            unreachable; // failed to acquire pthread_mutex_t
    }

    fn release(self: *BinarySemaphore) void {
        if (pthread_mutex_unlock(&self.mutex) != 0)
            unreachable; // failed to release pthread_mutex_t
    }

    fn wait(self: *BinarySemaphore, deadline: ?u64) bool {
        self.acquire();
        defer self.release();

        if (self.updated) {
            self.updated = false;
            return true;
        }

        self.updated = true;
        while (true) {
            if (!self.updated)
                return true;

            const deadline_ns = deadline orelse {
                if (pthread_cond_wait(&self.cond, &self.mutex) != 0)
                    unreachable; // failed wait on pthread_cond_t
                continue;
            };

            var ts: std.os.timespec = undefined;
            if (core.is_darwin) {
                var tv: std.os.darwin.timeval = undefined;
                if (std.os.darwin.gettimeofday(&tv, null) != 0)
                    unreachable; // failed to get realtime clock for pthread_cond_timedwait
                ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), tv.tv_sec);
                ts.tv_nsec = @intCast(@TypeOf(ts.tv_usec), tv.tv_nsec) * std.time.ns_per_us;
            } else {
                std.os.clock_gettime(std.os.CLOCK_REALTIME, &ts) catch {
                    unreachable; // failed to get realtime clock for pthread_cond_timedwait
                };
            }

            const now = Futex.nanotime();
            if (now > deadline_ns) {
                self.updated = false;
                return false;
            }

            const duration = deadline_ns - now;
            ts.tv_sec += @intCast(@TypeOf(ts.tv_sec), @divFloor(duration, std.time.ns_per_s));
            ts.tv_nsec += @intCast(@TypeOf(ts.tv_nsec), @mod(duration, std.time.ns_per_s));
            _ = pthread_cond_timedwait(&self.cond, &self.mutex, &ts);
        }
    }

    fn notify(self: *BinarySemaphore) void {
        self.acquire();
        defer self.release();

        if (!self.updated) {
            self.updated = true;
            return;
        }

        self.updated = false;
        if (pthread_cond_signal(&self.cond) != 0)
            unreachable; // failed to signal pthread_cond_t
    }
};

const pthread_cond_t = pthread_t;
const pthread_condattr_t = pthread_t;

const pthread_mutex_t = pthread_t;
const pthread_mutexattr_t = pthread_t;

const pthread_key_t = usize;
const pthread_t = extern struct {
    _opaque: [128]u8 align(16),
};

extern "c" fn malloc(bytes: usize) callconv(.C) ?*c_void;
extern "c" fn free(ptr: ?*c_void) callconv(.C) void;
extern "c" fn sched_yield() callconv(.C) c_int;

extern "c" fn pthread_mutex_init(m: *pthread_mutex_t, a: ?*const pthread_mutexattr_t) callconv(.C) c_int;
extern "c" fn pthread_mutex_lock(m: *pthread_mutex_t) callconv(.C) c_int;
extern "c" fn pthread_mutex_unlock(m: *pthread_mutex_t) callconv(.C) c_int;
extern "c" fn pthread_mutex_destroy(m: *pthread_mutex_t) callconv(.C) c_int;

extern "c" fn pthread_cond_init(c: *pthread_cond_t, a: ?*const pthread_condattr_t) callconv(.C) c_int;
extern "c" fn pthread_cond_wait(noalias c: *pthread_cond_t, noalias m: *pthread_mutex_t) callconv(.C) c_int;
extern "c" fn pthread_cond_timedwait(noalias c: *pthread_cond_t, noalias m: *pthread_mutex_t, noalias t: *const std.os.timespec) callconv(.C) c_int;
extern "c" fn pthread_cond_signal(c: *pthread_cond_t) callconv(.C) c_int;
extern "c" fn pthread_cond_destroy(c: *pthread_cond_t) callconv(.C) c_int;

extern "c" fn pthread_key_create(k: *pthread_key_t, d: fn(*c_void) callconv(.C) void) callconv(.C) c_int;
extern "c" fn pthread_getspecific(k: pthread_key_t) callconv(.C) ?*c_void;
extern "c" fn pthread_setspecific(k: pthread_key_t, v: ?*c_void) callconv(.C) c_int;

