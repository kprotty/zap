const std = @import("std");
const system = std.os.system;

pub const Lock = struct {
    srwlock: SRWLOCK = SRWLOCK_INIT,

    pub fn acquire(self: *Lock) void {
        AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn release(self: *Lock) void {
        ReleaseSRWLockExclusive(&self.srwlock);
    }

    const SRWLOCK = ?*c_void;
    const SRWLOCK_INIT: SRWLOCK = null;

    extern "kernel32" fn AcquireSRWLockExclusive(
        srwlock: *SRWLOCK,
    ) callconv(.Stdcall) void;

    extern "kernel32" fn ReleaseSRWLockExclusive(
        srwlock: *SRWLOCK,
    ) callconv(.Stdcall) void;
};
