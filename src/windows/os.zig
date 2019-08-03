// Basic data types

pub const WORD = u16;
pub const DWORD = u32;
pub const LPDWORD = *DWORD;
pub const SIZE_T = usize;
pub const LPVOID = *c_void;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const BOOL = c_int;

// System functions

pub const LPSYSTEM_INFO = *SYSTEM_INFO;
pub const SYSTEM_INFO = extern struct {
    dwOemId: DWORD,
    dwPageSize: DWORD,
    lpMinimumApplicationAddress: LPVOID,
    lpMaximumApplicationAddress: LPVOID,
    dwActiveProcessorMask: LPDWORD,
    dwNumberOfProcessors: DWORD,
    dwProcessorType: DWORD,
    dwAllocationGranularity: DWORD,
    wProcessorLevel: WORD,
    wProcessorRevision: WORD,
};

pub extern "kernel32" stdcallcc fn GetLastError() DWORD;

pub extern "kernel32" stdcallcc fn GetSystemInfo(
    lpSystemInfo: LPSYSTEM_INFO,
) void;

// Handles

pub const WAIT_OBJECT_0: DWORD = 0x0000;
pub const WAIT_TIMEOUT: DWORD = 0x0102;
pub const INFINITE: DWORD = ~DWORD(0);

pub const HANDLE = LPVOID;
pub const INVALID_HANDLE = @intToPtr(HANDLE, ~usize(0));

pub extern "kernel32" stdcallcc fn CloseHandle(
    hObject: HANDLE,
) BOOL;

pub extern "kernel32" stdcallcc fn WaitForSingleObject(
    hObject: HANDLE,
    dwMilliseconds: DWORD,
) DWORD;

// Virtual Memory

pub const MEM_COMMIT: DWORD = 0x1000;
pub const MEM_RESERVE: DWORD = 0x2000;
pub const MEM_DECOMMIT: DWORD = 0x4000;
pub const MEM_RELEASE: DWORD = 0x8000;

pub const PAGE_NOACCESS: DWORD = 0x01;
pub const PAGE_READONLY: DWORD = 0x02;
pub const PAGE_READWRITE: DWORD = 0x04;
pub const PAGE_EXECUTE: DWORD = 0x10;
pub const PAGE_EXECUTE_READ: DWORD = 0x20;
pub const PAGE_EXECUTE_READWRITE: DWORD = 0x40;

pub extern "kernel32" stdcallcc fn VirtualAlloc(
    lpAddress: ?LPVOID,
    dwSize: SIZE_T,
    flAllocationType: DWORD,
    flProtect: DWORD,
) ?LPVOID;

pub extern "kernel32" stdcallcc fn VirtualProtect(
    lpAddress: ?LPVOID,
    dwSize: SIZE_T,
    flNewProtect: DWORD,
    lpflOldProtect: LPDWORD,
) ?LPVOID;

pub extern "kernel32" stdcallcc fn VirtualFree(
    lpAddress: ?LPVOID,
    dwSize: SIZE_T,
    flFreeType: DWORD,
) BOOL;

// Thread functions

pub const LPTHREAD_START_ROUTINE = extern fn(lpParameter: LPVOID) DWORD;
pub const LPSECURITY_ATTRIBUTES = *SECURITY_ATTRIBUTES;
pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: LPVOID,
    bInheritHandle: BOOL,
};

pub extern "kernel32" stdcallcc fn GetCurrentThreadId() DWORD;

pub extern "kernel32" stdcallcc fn CreateThread(
    lpThreadAttributes: ?LPSECURITY_ATTRIBUTES,
    dwStackSize: SIZE_T,
    lpStartAddress: LPTHREAD_START_ROUTINE,
    lpParameter: ?LPVOID,
    dwCreationFlags: DWORD,
    lpThreadId: ?LPDWORD,
) ?HANDLE;