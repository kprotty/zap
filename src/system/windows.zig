const zap = @import("../../zap.zig");
const builtin = zap.builtin;

pub const WINAPI = switch (builtin.arch) {
    .i386 => .Stdcall,
    else => .C,
};

pub const BYTE = u8;
pub const WORD = u16;
pub const DWORD = u32;

pub const LARGE_INTEGER = i64;
pub const INFINITE = ~@as(DWORD, 0);

pub const BOOL = c_int;
pub const BOOLEAN = u8;
pub const TRUE = 1;
pub const FALSE = 0;

pub const SIZE_T = usize;
pub const LONG = c_long;
pub const ULONG = c_ulong;
pub const ULONG_PTR = if (@sizeOf(usize) > 4) u64 else ULONG;

pub const VOID = void;
pub const PVOID = *c_void;
pub const HANDLE = PVOID;

pub const SRWLOCK = ?PVOID;
pub const SRWLOCK_INIT: SRWLOCK = null;

pub const KSYSTEM_TIME = extern struct {
    LowPart: ULONG,
    High1Time: LONG,
    High2Time: LONG,
};

pub const NTSTATUS = DWORD;
pub const STATUS_SUCCESS: NTSTATUS = 0;
pub const STATUS_TIMEOUT: NTSTATUS = 0x102;

pub extern "kernel32" fn TryAcquireSRWLockExclusive(
    srwlock: *SRWLOCK,
) callconv(WINAPI) BOOL;

pub extern "kernel32" fn AcquireSRWLockExclusive(
    srwlock: *SRWLOCK,
) callconv(WINAPI) VOID;

pub extern "kernel32" fn ReleaseSRWLockExclusive(
    srwlock: *SRWLOCK,
) callconv(WINAPI) VOID;

pub extern "NtDll" fn NtYieldExecution() callconv(WINAPI) NTSTATUS; 

pub extern "NtDll" fn NtWaitForKeyedEvent(
    handle: ?HANDLE,
    key: ?*align(4) const c_void,
    alertable: BOOLEAN,
    timeout: ?*const LARGE_INTEGER,
) callconv(WINAPI) NTSTATUS;

pub extern "NtDll" fn NtReleaseKeyedEvent(
    handle: ?HANDLE,
    key: ?*align(4) const c_void,
    alertable: BOOLEAN,
    timeout: ?*const LARGE_INTEGER,
) callconv(WINAPI) NTSTATUS;