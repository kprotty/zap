pub const BYTE = u8;
pub const WORD = u16;
pub const DWORD = u32;
pub const LARGE_INTEGER = i64;

pub const VOID = c_void;
pub const PVOID = *VOID;
pub const HANDLE = PVOID;

pub const BOOL = i32;
pub const BOOLEAN = BYTE;
pub const TRUE = 1;
pub const FALSE = 0;

/////////////////////////////////////////////////////////////

pub const SYSTEM_INFO = extern struct {
    anon1: extern union {
        dwOemId: DWORD,
        anon2: extern struct {
            wProcessorArchitecture: WORD,
            wReserved: WORD,
        },
    },
    dwPageSize: DWORD,
    lpMinimumApplicationAddress: LPVOID,
    lpMaximumApplicationAddress: LPVOID,
    dwActiveProcessorMask: ?*DWORD,
    dwNumberOfProcessors: DWORD,
    dwProcessorType: DWORD,
    dwAllocationGranularity: DWORD,
    wProcessorLevel: WORD,
    wProcessorRevision: WORD,
};

pub const THREAD_START_ROUTINE = fn(
    lpParameter: PVOID,
) callconv(.C) DWORD;

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

pub extern "kernel32" fn QueryPerformanceCounter(
    pCounter: *LARGE_INTEGER,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn QueryPerformanceFrequency(
    pFrequency: *LARGE_INTEGER,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn CreateThread(
    lpThreadAttributes: ?PVOID,
    dwStackSize: SIZE_T,
    lpStartAddress: *THREAD_START_ROUTINE,
    lpParameter: ?PVOID,
    dwCreationFlags: DWORD,
    lpThreadId: ?*DWORD,
) callconv(.Stdcall) ?HANDLE;

pub extern "kernel32" fn WaitForSingleObject(
    hHandle: ?HANDLE,
    dwMilliseconds: DWORD,
) callconv(.Stdcall) DWORD;

pub extern "kernel32" fn CloseHandle(
    hHandle: ?HANDLE,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn GetSystemInfo(
    lpSystemInfo: *SYSTEM_INFO,
) callconv(.Stdcall) VOID;

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

