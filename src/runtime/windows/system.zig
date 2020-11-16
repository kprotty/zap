pub const BYTE = u8;
pub const WORD = u16;
pub const DWORD = u32;
pub const LARGE_INTEGER = i64;

pub const PVOID = *c_void;
pub const HANDLE = PVOID;

pub const BOOL = i32;
pub const BOOLEAN = BYTE;
pub const TRUE = 1;
pub const FALSE = 0;

/////////////////////////////////////////////////////////////

pub const SRWLOCK = ?PVOID;
pub const SRWLOCK_INIT: SRWLOCK = null;

pub extern "kernel32" fn AcquireSRWLockExclusive(
    srwlock: *SRWLOCK,
) callconv(.Stdcall) void;

pub extern "kernel32" fn ReleaseSRWLockExclusive(
    srwlock: *SRWLOCK,
) callconv(.Stdcall) void;

pub extern "kernel32" fn SleepEx(
    dwMilliseconds: DWORD,
    bAlertable: BOOL,
) callconv(.Stdcall) DWORD;

//////////////////////////////////////////////////////////////

pub const NTSTATUS = DWORD;
pub const STATUS_SUCCESS = 0;

pub extern "NtDll" fn NtWaitForKeyedEvent(
    handle: ?HANDLE,
    key: ?*align(4) const c_void,
    alertable: BOOLEAN,
    timeout: ?*const LARGE_INTEGER,
) callconv(.Stdcall) NTSTATUS;

pub extern "NtDll" fn NtReleaseKeyedEvent(
    handle: ?HANDLE,
    key: ?*align(4) const c_void,
    alertable: BOOLEAN,
    timeout: ?*const LARGE_INTEGER,
) callconv(.Stdcall) NTSTATUS;

