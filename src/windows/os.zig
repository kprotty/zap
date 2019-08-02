pub const DWORD = u32;
pub const PDWORD = *DWORD;
pub const SIZE_T = usize;
pub const LPVOID = *c_void;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const BOOL = c_int;

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
    flAllocationType: DWORD,
    flProtect: DWORD,
) ?LPVOID;

pub extern "kernel32" stdcallcc fn VirtualFree(
    lpAddress: ?LPVOID,
    dwSize: SIZE_T,
    flNewProtect: DWORD,
    lpflOldProtect: PDWORD,
) BOOL;