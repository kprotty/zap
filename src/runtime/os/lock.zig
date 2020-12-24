const builtin = @import("builtin");
const system = @import("./system.zig");
const Futex = @import("./futex.zig").Futex;
const Event = @import("./event.zig").Event;

const sync = @import("../../sync/sync.zig");
const UnfairLock = sync.UnfairLock;
const atomic = sync.atomic;

pub const Lock = switch (builtin.os.tag) {
    .macos, .ios, .watchos, .tvos => DarwinLock,
    .windows => WindowsLock,
    .linux => FutexLock,
    else => EventLock,
};

const WindowsLock = extern struct {
    srwlock: system.SRWLOCK = system.SRWLOCK_INIT,

    pub fn acquire(self: *WindowsLock) void {
        system.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn release(self: *WindowsLock) void {
        system.ReleaseSRWLockExclusive(&self.srwlock);
    }
};

const DarwinLock = extern struct {
    lock: system.os_unfair_lock = system.OS_UNFAIR_LOCK_INIT,

    pub fn acquire(self: *DarwinLock) void {
        system.os_unfair_lock_lock(&self.lock);
    }

    pub fn release(self: *DarwinLock) void {
        system.os_unfair_lock_lock(&self.lock);
    }
};

const EventLock = extern struct {
    lock: UnfairLock = .{},

    pub fn acquire(self: *EventLock) void {
        self.lock.acquire(Event);
    }

    pub fn release(self: *EventLock) void {
        self.lock.release();
    }
};

const FutexLock = extern struct {
    state: State = .unlocked,

    const State = extern enum(u32) {
        unlocked = 0,
        locked,
        waiting,
    };

    pub fn acquire(self: *FutexLock) void {
        const state = atomic.swap(&self.state, .locked, .acquire);
        if (state != .unlocked)
            self.acquireSlow(state);
    }

    fn acquireSlow(self: *FutexLock, current_state: State) void {
        @setCold(true);

        var spin_iter: usize = 0;
        var lock_state = current_state;
        
        while (true) {
            while (true) {
                switch (atomic.load(&self.state, .relaxed)) {
                    .unlocked => _ = atomic.tryCompareAndSwap(
                        &self.state,
                        .unlocked,
                        lock_state,
                        .acquire,
                        .relaxed,
                    ) orelse return,
                    .locked => {},
                    .waiting => break,
                }
                
                if (Futex.yield(spin_iter)) {
                    spin_iter +%= 1;
                } else {
                    break;
                }
            }

            spin_iter = 0;
            lock_state = .waiting;

            const state = atomic.swap(&self.state, .waiting, .acquire);
            if (state == .unlocked)
                return;

            const futex_ptr = @ptrCast(*const u32, &self.state);
            Futex.wait(
                futex_ptr,
                @enumToInt(lock_state),
                null,
            ) catch unreachable;
        }
    }

    pub fn release(self: *FutexLock) void {
        switch (atomic.swap(&self.state, .unlocked, .release)) {
            .unlocked => unreachable,
            .locked => {},
            .waiting => self.releaseSlow(),
        }
    }

    fn releaseSlow(self: *FutexLock) void {
        @setCold(true);

        const futex_ptr = @ptrCast(*const u32, &self.state);
        Futex.wake(futex_ptr);
    }
};
