const zap = @import("../../zap.zig");
const target = zap.runtime.target;

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
pub const ERROR_TIMEOUT = 0x5B4;

pub const SRWLOCK = ?PVOID;
pub const SRWLOCK_INIT: SRWLOCK = null;

pub const CONDITION_VARIABLE = ?PVOID;
pub const CONDITION_VARIABLE_INIT: CONDITION_VARIABLE = null;

pub const SYSTEM_INFO = extern struct {
    dwOemId: DWORD,
    dwPageSize: DWORD,
    lpMinimumApplicationAddress: PVOID,
    lpMaximumApplicationAddress: PVOID,
    dwActiveProcessorMask: SIZE_T,
    dwNumberOfProcessors: DWORD,
    dwProcessorType: DWORD,
    dwAllocationGranularity: DWORD,
    wProcessorLevel: WORD,
    wProcessorRevision: WORD,
};

pub const WINAPI = if (target.arch == .i386) .Stdcall else .C;

pub extern "kernel32" fn TryAcquireSRWLockExclusive(
    lock: *SRWLOCK,
) callconv(WINAPI) BOOL;

pub extern "kernel32" fn AcquireSRWLockExclusive(
    lock: *SRWLOCK,
) callconv(WINAPI) VOID;

pub extern "kernel32" fn ReleaseSRWLockExclusive(
    lock: *SRWLOCK,
) callconv(WINAPI) VOID;

pub extern "kernel32" fn WakeConditionVariable(
    cond: *CONDITION_VARIABLE,
) callconv(WINAPI) VOID;

pub extern "kernel32" fn SleepConditionVariableSRW(
    cond: *CONDITION_VARIABLE,
    lock: *SRWLOCK,
    dwMilliseconds: DWORD,
    flags: ULONG, 
) callconv(WINAPI) BOOL;

pub extern "kernel32" fn GetLastError() callconv(WINAPI) DWORD;

pub extern "kernel32" fn QueryPerformanceCounter(
    counter: *LARGE_INTEGER,
) callconv(WINAPI) BOOL;

pub extern "kernel32" fn QueryPerformanceFrequency(
    counter: *LARGE_INTEGER,
) callconv(WINAPI) BOOL;

pub extern "kernel32" fn CloseHandle(
    handle: HANDLE,
) callconv(WINAPI) BOOL;

pub extern "kernel32" fn GetSystemInfo(
    lpSystemInfo: *SYSTEM_INFO,
) callconv(WINAPI) VOID;

pub extern "kernel32" fn CreateThread(
    lpThreadAttributes: ?PVOID,
    dwStackSize: SIZE_T,
    lpStartAddress: fn(?PVOID) callconv(.C) DWORD,
    lpParameter: ?PVOID,
    dwCreationFlags: DWORD,
    lpThreadId: ?*DWORD,
) callconv(WINAPI) ?HANDLE;
