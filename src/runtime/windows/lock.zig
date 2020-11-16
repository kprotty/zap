const system = @import("./system.zig");

pub const Lock = struct {
    srwlock: system.SRWLOCK = system.SRWLOCK_INIT,

    pub fn acquire(self: *Lock) void {
        system.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn release(self: *Lock) void {
        system.ReleaseSRWLockExclusive(&self.srwlock);
    }
};
