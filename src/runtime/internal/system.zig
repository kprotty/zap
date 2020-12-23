const builtin = @import("builtin");

pub usingnamespace switch (builtin.os.tag) {
    .linux => LinuxSystem,
    .windows => WindowsSystem,
    .macos, .ios, .watchos, .tvos => DarwinSystem,
    else => struct{},
};

/// https://opensource.apple.com/source/xnu/xnu-6153.81.5/bsd/sys/errno.h.auto.html
/// https://opensource.apple.com/source/xnu/xnu-6153.81.5/bsd/sys/ulock.h.auto.html
const DarwinSystem = struct {
    pub const EINTR = 4;
    pub const ENOENT = 2;
    pub const ETIMEDOUT = 60;

    pub const mach_timebase_info_data_t = extern struct {
        numer: u32,
        denom: u32,
    };
    
    pub extern "c" fn mach_absolute_time() callconv(.C) u64;
    pub extern "c" fn mach_timebase_info(
        data: ?*mach_timebase_info_data_t,
    ) callconv(.C) c_int;

    pub const ULF_NO_ERRNO = 0x1000000;
    pub const UL_COMPARE_AND_WAIT = 0x1;
    
    pub extern "c" fn __ulock_wait(
        operation: u32,
        address: ?*const c_void,
        value: u64,
        timeout_us: u32,
    ) callconv(.C) c_int;

    pub extern "c" fn __ulock_wake(
        operation: u32,
        address: ?*const c_void,
        value: u64,
    ) callconv(.C) c_int;
};

const WindowsSystem = struct {
    pub const WINAPI = if (builtin.arch == .i386) .Stdcall else .C;

    pub const BYTE = u8;
    pub const WORD = u16;
    pub const DWORD = u32;
    pub const LARGE_INTEGER = i64;

    pub const SIZE_T = usize;
    pub const ULONG_PTR = switch (builtin.arch) {
        .x86_64, .aarch64 => u64,
        .i386, .arm => c_ulong,
        else => unreachable,
    };

    pub const BOOL = c_int;
    pub const BOOLEAN = BYTE;
    pub const TRUE = 1;
    pub const FALSE = 0;

    pub const VOID = void;
    pub const PVOID = *c_void;
    pub const HANDLE = PVOID;

    pub const NTSTATUS = DWORD;
    pub const STATUS_SUCCESS: NTSTATUS = 0x000;
    pub const STATUS_TIMEOUT: NTSTATUS = 0x102;

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

    pub const PROCESSOR_NUMBER = extern struct {
        Group: WORD,
        Number: BYTE,
        Reserved: BYTE,
    };

    pub const KAFFINITY = ULONG_PTR;
    pub const GROUP_AFFINITY = extern struct {
        Mask: KAFFINITY,
        Group: WORD,
        Reserved: [3]WORD,
    };

    pub extern "kernel32" fn CloseHandle(
        handle: ?HANDLE,
    ) callconv(WINAPI) BOOL;

    pub extern "kernel32" fn CreateThread(
        lpThreadAttributes: ?PVOID,
        dwStackSize: SIZE_T,
        lpStartAddress: fn(?PVOID) callconv(.C) DWORD,
        lpParameter: ?PVOID,
        dwCreationFlags: DWORD,
        dwThreadId: ?*DWORD,
    ) callconv(WINAPI) ?HANDLE;

    pub extern "kernel32" fn GetNumaNodeProcessorMaskEx(
        nNode: WORD,
        pProcessorMask: ?*GROUP_AFFINITY,
    ) callconv(WINAPI) BOOL;

    pub extern "kernel32" fn SetThreadIdealProcessorEx(
        hThread: ?HANDLE,
        lpIdealProcessor: ?*const PROCESSOR_NUMBER,
        lpPrevIdealProcessor: ?*PROCESSOR_NUMBER,
    ) callconv(WINAPI) BOOL;

    pub extern "kernel32" fn SetThreadGroupAffinity(
        hThread: ?HANDLE,
        lpGroupAffinity: ?*const GROUP_AFFINITY,
        lpPrevGroupAffinity: ?*GROUP_AFFINITY,
    ) callconv(WINAPI) BOOL;
};

const LinuxSystem = struct {

    pub usingnamespace switch (builtin.arch) {
        .x86_64 => struct {

            pub fn syscall(op: usize, args: anytype) usize {
                return asm volatile("syscall"
                    : [ret] "={rax}" (-> usize)
                    : [op] "{rax}" (op),
                        [a1] "{rdi}" (if ()))
            }
        }
    }
};