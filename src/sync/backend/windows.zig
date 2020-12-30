const zap = @import(".../zap.zig");
const atomic = zap.sync.atomic;
const Clock = zap.time.OsClock;
const system = zap.system;

pub const Lock = extern struct {
    srwlock: system.SRWLOCK = system.SRWLOCK_INIT,

    pub fn acquire(self: *Lock) void {
        system.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn tryAcquire(self: *Lock) bool {
        return system.TryAcquireSRWLockExclusive(&self.srwlock) == system.TRUE;
    }

    pub fn release(self: *Lock) void {
        system.ReleaseSRWLockExclusive(&self.srwlock);
    }
};

pub const Event = extern struct {
    state: extern enum(u32){
        empty,
        waiting,
        notified,
    } align(4),

    pub fn init(self: *Event) void {
        self.state = .empty;
    }

    pub fn deinit(self: *Event) void {
        self.* = undefined;
    }

    pub fn wait(self: *Event, deadline: ?u64, condition: anytype) error{TimedOut}!void {
        if (!condition.wait())
            return;

        if (atomic.compareAndSwap(
            &self.state,
            .empty,
            .waiting,
            .acquire,
            .acquire,
        )) |state| {
            if (state != .notified)
                unreachable;
            return;
        }
        
        var timed_out = false;
        var timeout: system.LARGE_INTEGER = undefined;
        var timeout_ptr: ?*const system.LARGE_INTEGER = null;
        if (deadline) |deadline_ns| {
            const now = nanotime();
            timed_out = now > deadline_ns;
            if (!timed_out) {
                timeout_ptr = &timeout;
                timeout = -@intCast(system.LARGE_INTEGER, (deadline_ns - now) / 100);
            }
        }

        if (!timed_out) {
            switch (system.NtWaitForKeyedEvent(
                @as(?system.HANDLE, null),
                @ptrCast(*align(4) const c_void, &self.state),
                system.FALSE,
                timeout_ptr,
            )) {
                system.STATUS_SUCCESS => return,
                system.STATUS_TIMEOUT => {},
                else => unreachable,
            }
        }

        if (atomic.compareAndSwap(
            &self.state,
            .waiting,
            .empty,
            .acquire,
            .acquire,
        )) |state| {
            if (state != .notified)
                unreachable;
            switch (system.NtWaitForKeyedEvent(
                @as(?system.HANDLE, null),
                @ptrCast(*align(4) const c_void, &self.state),
                system.FALSE,
                @as(?*const system.LARGE_INTEGER, null),
            )) {
                system.STATUS_SUCCESS => return,
                else => unreachable,
            }
        }

        return error.TimedOut;
    }

    pub fn notify(self: *Event) void {
        switch (atomic.swap(&self.state, .notified, .release)) {
            .empty => return,
            .waiting => {},
            .notified => unreachable,
        }

        switch (system.NtReleaseKeyedEvent(
            @as(?system.HANDLE, null),
            @ptrCast(*align(4) const c_void, &self.state),
            system.FALSE,
            @as(?*const system.LARGE_INTEGER, null),
        )) {
            system.STATUS_SUCCESS => return,
            else => unreachable,
        }
    }

    pub fn yield(iteration: ?usize) bool {
        const iter = iteration orelse {
            _ = system.NtYieldExecution();
            return false;
        };

        if (iter < 4000) {
            atomic.spinLoopHint();
            return true;
        }

        return false;
    }

    pub fn nanotime() u64 {
        return Clock.readMonotonicTime();
    }
};