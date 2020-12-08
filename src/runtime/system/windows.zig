pub const CHAR = u8;
pub const WORD = u16;
pub const DWORD = u32;
pub const DWORD64 = u64;
pub const SIZE_T = usize;

pub const BYTE = CHAR;
pub const SHORT = WORD;
pub const LONG = i32;
pub const ULONG = DWORD;
pub const LONGLONG = i64;
pub const ULONGLONG = u64;

pub const BOOL = u8;
pub const TRUE = 1;
pub const FALSE = 0;

pub const VOID = void;
pub const PVOID = *c_void;
pub const HANDLE = PVOID;
pub const HMODULE = HANDLE;

pub const LARGE_INTEGER = i64;
pub const INFINITE = ~@as(DWORD, 0);

pub const WAIT_OBJECT_0 = 0x0;
pub const WAIT_IO_COMPLETION = 0xC0;
pub const WAIT_ABANDONED = 0x80;
pub const WAIT_TIMEOUT = 0x102;
pub const WAIT_FAILED = ~@as(DWORD, 0);

pub const ERROR_TIMEOUT = 0x5B4;

pub const SRWLOCK = ?PVOID;
pub const SRWLOCK_INIT: SRWLOCK = null;

pub const CONDITION_VARIABLE = ?PVOID;
pub const CONDITION_VARIABLE_INIT: CONDITION_VARIABLE = null;

pub extern "kernel32" fn TryAcquireSRWLockExclusive(
    lock: *SRWLOCK,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn AcquireSRWLockExclusive(
    lock: *SRWLOCK,
) callconv(.Stdcall) VOID;

pub extern "kernel32" fn ReleaseSRWLockExclusive(
    lock: *SRWLOCK,
) callconv(.Stdcall) VOID;

pub extern "kernel32" fn WakeConditionVariable(
    cond: *CONDITION_VARIABLE,
) callconv(.Stdcall) VOID;

pub extern "kernel32" fn SleepConditionVariableSRW(
    cond: *CONDITION_VARIABLE,
    lock: *SRWLOCK,
    dwMilliseconds: DWORD,
    flags: ULONG, 
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn GetLastError() callconv(.Stdcall) DWORD;

pub extern "kernel32" fn QueryPerformanceCounter(
    counter: *LARGE_INTEGER,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn QueryPerformanceFrequency(
    counter: *LARGE_INTEGER,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn CloseHandle(
    handle: HANDLE,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn WaitForSingleObjectEx(
    handle: HANDLE,
    dwMilliseconds: DWORD,
    bAlertable: BOOL,
) callconv(.Stdcall) DWORD;

pub extern "kernel32" fn CreateThread(
    lpThreadAttributes: ?PVOID,
    dwStackSize: SIZE_T,
    lpStartAddress: fn(?PVOID) callconv(.C) DWORD,
    lpParameter: ?PVOID,
    dwCreationFlags: DWORD,
    lpThreadId: ?*DWORD,
) callconv(.Stdcall) ?HANDLE;
