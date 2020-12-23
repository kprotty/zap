const builtin = @import("builtin");
const system = @import("./system.zig");
const Futex = @import("./futex.zig").Futex;

const sync = @import("../../sync/sync.zig");
const atomic = sync.atomic;

pub const Lock = switch (builtin.os.tag) {
    .macos, .ios, .watchos, .tvos => DarwinLock,
    .windows => WindowsLock,
    else => FutexLock,
};

const WindowsLock = struct {
    srwlock: system.SRWLOCK = system.SRWLOCK_INIT,

    pub fn acquire(self: *Lock) void {
        system.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn release(self: *Lock) void {
        system.ReleaseSRWLockExclusive(&self.srwlock);
    }
};

const DarwinLock = struct {
    lock: system.os_unfair_lock = system.OS_UNFAIR_LOCK_INIT,

    pub fn acquire(self: *Lock) void {
        system.os_unfair_lock_lock(&self.lock);
    }

    pub fn release(self: *Lock) void {
        system.os_unfair_lock_lock(&self.lock);
    }
};

const FutexLock = struct {
    state: enum(u32){
        unlocked = 0,
        locked,
        waiting,
    } = .unlocked,

    pub fn acquire(self: *Lock) void {
        const state = atomic.swap(&self.state, .locked, .acquire);
        if (state != .unlocked)
            self.acquireSlow(state);
    }

    fn acquireSlow(self: *Lock, current_state: @TypeOf(@as(Lock, undefined).state)) void {
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

    pub fn release(self: *Lock) void {
        switch (atomic.swap(&self.state, .unlocked, .release)) {
            .unlocked => unreachable,
            .locked => {},
            .waiting => self.releaseSlow(),
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        const futex_ptr = @ptrCast(*const u32, &self.state);
        Futex.wake(futex_ptr);
    }
};
