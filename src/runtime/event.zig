const zap = @import("../zap.zig");
const target = zap.runtime.target;
const atomic = zap.sync.atomic;
const nanotime = zap.runtime.nanotime;

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
    waiting: bool = false,
    lock: system.SRWLOCK = system.SRWLOCK_INIT,
    cond: system.CONDITION_VARIABLE = system.CONDITION_VARIABLE_INIT,

    pub fn wait(self: *Event, deadline: ?u64, condition: anytype) bool {
        system.AcquireSRWLockExclusive(&self.lock);
        defer system.ReleaseSRWLockExclusive(&self.lock);

        if (!condition.wait())
            return true;

        self.waiting = true;
        while (self.waiting) {

            var timeout = system.INFINITE;
            if (deadline) |deadline_ns| {
                const now = nanotime();
                if (now > deadline_ns) {
                    self.waiting = false;
                    return false;
                } else {
                    const timeout_ns = deadline_ns - now;
                    timeout = @divFloor(timeout_ns, 1_000_000); 
                }
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

        if (self.waiting) {
            self.waiting = false;
            system.WakeConditionVariable(&self.cond);
        }
    }
};

const PosixEvent = struct {
    pub fn wait(self: *Event, deadline: ?u64, condition: anytype) bool {

    }

    pub fn notify(self: *Event) void {

    }
};

