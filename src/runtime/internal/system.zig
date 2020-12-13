const builtin = @import("builtin");

pub usingnamespace switch (builtin.os.tag) {
    .linux => Linux,
    .windows => Windows,
    .netbsd => NetBSD,
    .openbsd => OpenBSD,
    .dragonfly => Dragonfly,
    .freebsd, .kfreebsd => FreeBSD,
    .macos, .ios, .watchos, .tvos => Darwin,
    else => struct{},
};

const Windows = struct {
    const WINAPI = if (builtin.arch == .i386) .Stdcall else .C;

    pub const BYTE = u8;
    pub const WORD = u16;
    pub const DWORD = u32;
    pub const SIZE_T = usize;

    pub const BOOL = u8;
    pub const TRUE = 1;
    pub const FALSE = 0;

    pub const VOID = void;
    pub const PVOID = *c_void;
    pub const HANDLE = PVOID;

    pub const INFINITE = ~@as(DWORD, 0);
    pub const ERROR_TIMEOUT = 0x584;

    pub extern "kernel32" fn GetLastError() callconv(WINAPI) DWORD;

    pub const LARGE_INTEGER = i64;

    pub extern "kernel32" fn QueryPerformanceCounter(
        counter: *LARGE_INTEGER,
    ) callconv(WINAPI) BOOL;

    pub extern "kernel32" fn QueryPerformanceFrequency(
        counter: *LARGE_INTEGER,
    ) callconv(WINAPI) BOOL;

    pub const SRWLOCK = ?PVOID;
    pub const SRWLOCK_INIT: SRWLOCK = null;

    pub extern "kernel32" fn AcquireSRWLockExclusive(
        lock: *SRWLOCK,
    ) callconv(WINAPI) VOID;

    pub extern "kernel32" fn ReleaseSRWLockExclusive(
        lock: *SRWLOCK,
    ) callconv(WINAPI) VOID;

    pub const CONDITION_VARIABLE = ?PVOID;
    pub const CONDITION_VARIABLE_INIT: SRWLOCK = null;

    pub extern "kernel32" fn WakeConditionVariable(
        cond: *CONDITION_VARIABLE,
    ) callconv(WINAPI) VOID;

    pub extern "kernel32" fn SleepConditionVariableSRW(
        cond: *CONDITION_VARIABLE,
        lock: *SRWLOCK,
        dwMilliseconds: DWORD,
        flags: DWORD, 
    ) callconv(WINAPI) BOOL;
};

const Linux = struct {

};

const Darwin = struct {
    pub const mach_timebase_info_data_t = extern struct {
        numer: u32,
        denom: u32,
    };
    pub extern "c" fn mach_absolute_time() callconv(.C) u64;
    pub extern "c" fn mach_timebase_info(
        data: ?*mach_timebase_info_data_t,
    ) callconv(.C) void;

    pub const timespec = extern struct {
        tv_sec: i64,
        tv_nsec: i64,
    };
    pub const timeval = extern struct {
        tv_sec: i64,
        tv_usec: i32,
    };
    pub const timezone = extern struct {
        tz_minuteswest: i32,
        tz_dsttime: i32,
    };
    pub extern "c" fn gettimeofday(
        noalias tv: ?*timeval,
        noalias tz: ?*timezone,
    ) callconv(.C) c_int; 

    pub const pthread_t = usize;
    pub const pthread_attr_t = extern struct {
        _sig: i64,
        _opaque: [56]u8,
    };

    pub const pthread_mutex_t = extern struct {
        _sig: i64,
        _opaque: [56]u8,
    };
    pub const pthread_mutexattr_t = extern struct {
        _sig: i64,
        _opaque: [8]u8,
    };
    
    pub const pthread_cond_t = extern struct {
        _sig: i64,
        _opaque: [40]u8,
    };
    pub const pthread_condattr_t = extern struct {
        _sig: i64,
        _opaque: [8]u8,
    };
    
};

const NetBSD = struct {

};

const OpenBSD = struct {

};

const FreeBSD = struct {

};

const Dragonfly = struct {

};