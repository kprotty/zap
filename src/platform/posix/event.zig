const std = @import("std");
const zap = @import("../../zap.zig");
const LinuxEvent = @import("../linux/event.zig").Event;

const system = std.os.system;
const sync = zap.core.sync;
const platform = zap.platform;

const Condition = sync.Condition;
const Atomic = sync.atomic.Atomic;

pub const Event = extern struct {
    event: Atomic(?*PthreadEvent) = Atomic(?*PthreadEvent).init(null),

    pub fn wait(self: *Event, deadline: ?u64, condition: *Condition, comptime nanotimeFn: anytype) bool {
        var has_stack_event = false;
        var stack_event: PthreadEvent = undefined;
        defer if (has_stack_event)
            stack_event.deinit();

        const event = PthreadEvent.get() orelse blk: {
            stack_event.init() catch unreachable;
            has_stack_event = true;
            break :blk &stack_event;
        };

        event.reset();
        self.event.set(event);
        if (condition.isMet())
            return true;

        event.wait(deadline, nanotimeFn);
        if (self.event.load(.acquire) == null)
            return true;

        if (self.event.swap(null, .acquire) == null)
            event.wait(null, nanotimeFn);
        return false;
    }

    pub fn notify(self: *Event) void {
        if (self.event.swap(null, .acq_rel)) |event|
            event.notify();
    }

    pub const is_actually_monotonic = 
        if (platform.is_linux) LinuxEvent.is_actually_monotonic
        else true;

    pub fn nanotime(comptime getCachedFn: anytype) u64 {
        if (platform.is_darwin) {
            const frequency = getCachedFn(struct {
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
        clock_gettime("CLOCK_MONOTONIC", &ts);
        return (@intCast(u64, ts.tv_sec) * std.time.ns_per_s) + @intCast(u64, ts.tv_nsec);
    }

    fn clock_gettime(comptime clock_id: []const u8, ts: *system.timespec) void {
        const rc = system.clock_gettime(@field(system, clock_id), ts);
        if (system.getErrno(rc) != 0)
            @panic("clock_gettime(" ++ clock_id ++ ") unhandled errno");
    }

    const PthreadEvent = struct {
        is_waiting: bool,
        is_notified: bool,
        cond: pthread_cond_t,
        mutex: pthread_mutex_t,

        fn init(self: *PthreadEvent) !void {
            var cond_attr: pthread_condattr_t = undefined;
            var cond_attr_ptr: ?*pthread_condattr_t = null;
            const use_clock_monotonic = !platform.is_darwin and !platform.is_android;

            if (use_clock_monotonic and pthread_condattr_init(&cond_attr) != 0)
                return error.PthreadCondAttrInit;
            defer if (use_clock_monotonic) {
                _ = pthread_condattr_destroy(&cond_attr);
            };

            if (use_clock_monotonic) {
                cond_attr_ptr = &cond_attr;
                if (pthread_condattr_setclock(&cond_attr, system.CLOCK_MONOTONIC) != 0)
                    return error.PthreadCondAttrSetClock;
            }

            if (pthread_cond_init(&self.cond, cond_attr_ptr) != 0)
                return error.PthreadCondInit;
            errdefer _ = pthread_cond_destroy(&self.cond);

            if (pthread_mutex_init(&self.mutex, null) != 0)
                return error.PthreadMutexInit;
            errdefer _ = pthread_mutex_destroy(&self.mutex);
        }

        fn deinit(self: *PthreadEvent) void {
            if (pthread_cond_destroy(&self.cond) != 0)
                @panic("pthread_cond_destroy() failed");
            if (pthread_mutex_destroy(&self.mutex) != 0)
                @panic("pthread_mutex_destroy() failed");
        }

        fn lock(self: *PthreadEvent) void {
            if (pthread_mutex_lock(&self.mutex) != 0)
                @panic("pthread_mutex_lock() failed");
        }

        fn unlock(self: *PthreadEvent) void {
            if (pthread_mutex_unlock(&self.mutex) != 0)
                @panic("pthread_mutex_unlock() failed");
        }

        fn reset(self: *PthreadEvent) void {
            self.is_waiting = true;
            self.is_notified = false;
        }

        fn wait(self: *PthreadEvent, deadline: ?u64, comptime nanotimeFn: anytype) void {
            self.lock();
            defer self.unlock();

            while (!self.is_notified) {
                const deadline_ns = deadline orelse {
                    if (pthread_cond_wait(&self.cond, &self.mutex) != 0)
                        @panic("pthread_cond_wait() failed");
                    continue;
                };

                const now = nanotimeFn();
                if (now > deadline_ns) {
                    self.is_waiting = false;
                    return;
                }

                var ts: system.timespec = undefined;
                if (platform.is_darwin) {
                    var tv: system.timeval = undefined;
                    if (system.gettimeofday(&tv, null) != 0)
                        @panic("gettimeofday() failed");
                    ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), tv.tv_sec);
                    ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), tv.tv_usec) * std.time.ns_per_us;
                } else if (platform.is_android) {
                    clock_gettime("CLOCK_REALTIME", &ts);
                } else {
                    clock_gettime("CLOCK_MONOTONIC", &ts);
                }

                const duration = deadline_ns - now;
                ts.tv_sec += @intCast(@TypeOf(ts.tv_sec), @divFloor(duration, std.time.ns_per_s));
                ts.tv_nsec += @intCast(@TypeOf(ts.tv_nsec), @mod(duration, std.time.ns_per_s));

                const rc = pthread_cond_timedwait(&self.cond, &self.mutex, &ts);
                switch (rc) {
                    0, system.ETIMEDOUT => {},
                    else => @panic("pthread_cond_timedwait() unhandled errno"),
                }
            }
        }

        fn notify(self: *PthreadEvent) void {
            self.lock();
            defer self.unlock();

            self.is_notified = true;
            if (self.is_waiting) {
                if (pthread_cond_signal(&self.cond) != 0)
                    @panic("pthread_cond_signal() failed");
            }
        }

        var event_key: pthread_key_t = undefined;
        var event_key_state = Atomic(EventKeyState).init(.uninit);

        const EventKeyState = enum(usize) {
            uninit,
            loading,
            init,
            invalid,
        };

        fn getEventKey() ?pthread_key_t {
            if (event_key_state.load(.acquire) == .init)
                return event_key;
            return getEventKeySlow();
        }

        fn getEventKeySlow() ?pthread_key_t {
            @setCold(true);

            var state = event_key_state.load(.acquire);
            while (true) {
                state = switch (state) {
                    .uninit => event_key_state.tryCompareAndSwap(
                        .uninit,
                        .loading,
                        .acquire,
                        .acquire,
                    ) orelse blk: {
                        state = .init;
                        if (pthread_key_create(&event_key, destructor) != 0)
                            state = .invalid;
                        event_key_state.store(state, .release);
                        break :blk state;
                    },
                    .loading => blk: {
                        _ = sched_yield();
                        break :blk event_key_state.load(.acquire);
                    },
                    .init => return event_key,
                    .invalid => return null,
                };
            }
        }

        fn constructor() ?*c_void {
            const ptr = malloc(@sizeOf(PthreadEvent)) orelse return null;
            const event = @ptrCast(*PthreadEvent, @alignCast(@alignOf(PthreadEvent), ptr));
            event.init() catch {
                free(ptr);
                return null;
            };
            return ptr;
        }

        fn destructor(ptr: *c_void) callconv(.C) void {
            const event = @ptrCast(*PthreadEvent, @alignCast(@alignOf(PthreadEvent), ptr));
            event.deinit();
            free(ptr);
        }

        fn get() ?*PthreadEvent {
            const key = getEventKey() orelse return null;

            const ptr = pthread_getspecific(key) orelse blk: {
                const ptr = constructor() orelse return null;
                if (pthread_setspecific(key, ptr) == 0)
                    break :blk ptr;
                destructor(ptr);
                return null;
            };

            const event = @ptrCast(*PthreadEvent, @alignCast(@alignOf(PthreadEvent), ptr));
            return event;
        }

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

        extern "c" fn pthread_mutex_init(m: *pthread_mutex_t, a: ?*pthread_mutexattr_t) callconv(.C) c_int;
        extern "c" fn pthread_mutex_lock(m: *pthread_mutex_t) callconv(.C) c_int;
        extern "c" fn pthread_mutex_unlock(m: *pthread_mutex_t) callconv(.C) c_int;
        extern "c" fn pthread_mutex_destroy(m: *pthread_mutex_t) callconv(.C) c_int;

        extern "c" fn pthread_condattr_init(a: *pthread_condattr_t) callconv(.C) c_int;
        extern "c" fn pthread_condattr_setclock(a: *pthread_condattr_t, clock_id: c_int) callconv(.C) c_int;
        extern "c" fn pthread_condattr_destroy(a: *pthread_condattr_t) callconv(.C) c_int;

        extern "c" fn pthread_cond_init(c: *pthread_cond_t, a: ?*pthread_condattr_t) callconv(.C) c_int;
        extern "c" fn pthread_cond_wait(noalias c: *pthread_cond_t, noalias m: *pthread_mutex_t) callconv(.C) c_int;
        extern "c" fn pthread_cond_timedwait(noalias c: *pthread_cond_t, noalias m: *pthread_mutex_t, noalias t: *const system.timespec) callconv(.C) c_int;
        extern "c" fn pthread_cond_signal(c: *pthread_cond_t) callconv(.C) c_int;
        extern "c" fn pthread_cond_destroy(c: *pthread_cond_t) callconv(.C) c_int;

        extern "c" fn pthread_key_create(k: *pthread_key_t, d: fn(*c_void) callconv(.C) void) callconv(.C) c_int;
        extern "c" fn pthread_getspecific(k: pthread_key_t) callconv(.C) ?*c_void;
        extern "c" fn pthread_setspecific(k: pthread_key_t, v: ?*c_void) callconv(.C) c_int;
    };
};