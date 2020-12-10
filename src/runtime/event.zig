const zap = @import("../zap.zig");
const target = zap.runtime.target;
const atomic = zap.sync.atomic;
const system = zap.runtime.system;
const ns_per_s = zap.time.ns_per_s;
const ns_per_us = zap.time.ns_per_us;
const nanotime = zap.runtime.Clock.nanotime;

pub const Event = 
    if (target.is_windows)
        WindowsEvent
    else if (target.has_libc and target.is_posix)
        PosixEvent
    else if (target.is_linux)
        LinuxEvent
    else
        @compileError("OS not supported for thread blocking/unblocking");

const LinuxEvent = struct {
    pub fn wait(self: *Event, deadline: ?u64, condition: anytype) bool {

    }

    pub fn notify(self: *Event) void {

    }
};

const WindowsEvent = struct {
    state: State,
    lock: system.SRWLOCK,
    cond: system.CONDITION_VARIABLE,

    const State = enum {
        empty = 0,
        waiting,
        notified,
    };

    pub fn init(self: *Event) void {
        self.* = Event{
            .state = .empty,
            .lock = system.SRWLOCK_INIT,
            .cond = system.CONDITION_VARIABLE_INIT,
        };
    }

    pub fn deinit(self: *Event) void {
        self.* = undefined;
    }

    pub fn wait(self: *Event, deadline: ?u64, condition: anytype) bool {
        system.AcquireSRWLockExclusive(&self.lock);
        defer system.ReleaseSRWLockExclusive(&self.lock);

        if (!condition.wait())
            return true;

        switch (self.state) {
            .empty => self.state = .waiting,
            .waiting => unreachable,
            .notified => return true,
        }

        while (true) {
            switch (self.state) {
                .empty => unreachable,
                .waiting => {},
                .notified => return true,
            }

            var timeout = system.INFINITE;
            if (deadline) |deadline_ns| {
                const now = nanotime();
                if (now > deadline_ns) {
                    self.state = .empty;
                    return false;
                }

                const timeout_ms = @divFloor(deadline_ns - now, 1_000_000); 
                if (timeout_ms <= ~@as(@TypeOf(timeout), 0))
                    timeout = @intCast(@TypeOf(timeout), timeout_ms);
            }

            const status = system.SleepConditionVariableSRW(&self.cond, &self.lock, timeout, 0);
            if (status != system.FALSE)
                continue;

            switch (system.GetLastError()) {
                system.ERROR_TIMEOUT => {},
                else => unreachable,
            }
        }
    }

    pub fn notify(self: *Event) void {
        system.AcquireSRWLockExclusive(&self.lock);
        defer system.ReleaseSRWLockExclusive(&self.lock);

        const old_state = self.state;
        self.state = .notified;

        if (old_state == .waiting) {
            system.WakeConditionVariable(&self.cond);
        }
    }
};

const PosixEvent = struct {
    state: State,
    cond: system.pthread_cond_t,
    mutex: system.pthread_mutex_t,

    const State = enum {
        empty,
        waiting,
        notified,
    };

    pub fn init(self: *PosixEvent) void {
        self.state = .empty;
        if (system.pthread_mutex_init(&self.mutex, null) != 0)
            unreachable;
        if (system.pthread_cond_init(&self.cond, null) != 0)
            unreachable;
    }

    pub fn deinit(self: *PosixEvent) void {
        if (system.pthread_mutex_destroy(&self.mutex) != 0)
            unreachable;
        if (system.pthread_cond_destroy(&self.cond) != 0)
            unreachable;
    }

    pub fn wait(self: *Event, deadline: ?u64, condition: anytype) bool {
        if (system.pthread_mutex_lock(&self.mutex) != 0)
            unreachable;
        defer if (system.pthread_mutex_unlock(&self.mutex) != 0)
            unreachable;
        
        if (!condition.wait())
            return true;

        switch (self.state) {
            .empty => self.state = .waiting,
            .waiting => unreachable,
            .notified => return true,
        }

        while (true) {
            switch (self.state) {
                .empty => unreachable,
                .waiting => {},
                .notified => return true,
            }

            const deadline_ns = deadline orelse {
                if (system.pthread_cond_wait(&self.cond, &self.mutex) != 0)
                    unreachable;
                continue;
            };

            const now = nanotime();
            if (now > deadline_ns) {
                self.state = .empty;
                return false;
            }

            const realtime_now = blk: {
                if (target.is_darwin) {
                    var tv: system.timeval = undefined;
                    if (system.errno(system.gettimeofday(&tv, null)) != 0)
                        unreachable;
                    break :blk (@intCast(u64, tv.tv_sec) * ns_per_s) + (@intCast(u64, tv.tv_ussc) * ns_per_us);
                }

                var ts: system.timespec = undefined;
                if (system.errno(system.clock_gettime(system.CLOCK_REALTIME, &ts)) != 0)
                    unreachable;
                break :blk (@intCast(u64, ts.tv_sec) * ns_per_s) + @intCast(u64, ts.tv_nsec);             
            };
            
            var ts: system.timespec = undefined;
            const timeout_ns = realtime_now + (deadline_ns - now);
            ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), timeout_ns / ns_per_s);
            ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), timeout_ns % ns_per_s);

            _ = system.pthread_cond_timedwait(&self.cond, &self.mutex, &ts);
        }
    }

    pub fn notify(self: *Event) void {
        if (system.pthread_mutex_lock(&self.mutex) != 0)
            unreachable;
        defer if (system.pthread_mutex_unlock(&self.mutex) != 0)
            unreachable;
    }
};

