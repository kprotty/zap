const std = @import("std");
pub usingnamespace std.os.windows;

pub fn isOSVersionOrHigher(comptime target: std.Target.Os.WindowsVersion) bool {
    const current = std.builtin.os.version_range.windows.max;
    return @enumToInt(current) >= @enumToInt(target); 
}

pub const SRWLOCK = usize;
pub const PSRWLOCK = *SRWLOCK;
pub const SRWLOC_INIT: SRWLOCK = 0;

pub const STACK_SIZE_PARAM_IS_A_RESERVATION: DWORD = 0x10000;

pub const LOGICAL_PROCESSOR_RELATIONSHIP = DWORD;
pub const RelationCache: LOGICAL_PROCESSOR_RELATIONSHIP = 2;
pub const RelationNumaNode: LOGICAL_PROCESSOR_RELATIONSHIP = 1;
pub const RelationProcessorCore: LOGICAL_PROCESSOR_RELATIONSHIP = 0;
pub const RelationProcessorPackage: LOGICAL_PROCESSOR_RELATIONSHIP = 3;
pub const RelationGroup: LOGICAL_PROCESSOR_RELATIONSHIP = 4;
pub const RelationAll: LOGICAL_PROCESSOR_RELATIONSHIP = 0xffff;

pub const CacheUnified = PROCESSOR_CACHE_TYPE.CacheUnified;
pub const CacheInstruction = PROCESSOR_CACHE_TYPE.CacheInstruction;
pub const CacheData = PROCESSOR_CACHE_TYPE.CacheData;
pub const CacheTrace = PROCESSOR_CACHE_TYPE.CacheTrace;

pub const KAFFINITY = usize;
pub const GROUP_AFFINITY = extern struct {
    Mask: KAFFINITY,
    Group: WORD,
    Reserved: [3]WORD,
};

pub const PROCESSOR_CACHE_TYPE = extern enum {
    CacheUnified,
    CacheInstruction,
    CacheData,
    CacheTrace,
};

pub const PROCESSOR_GROUP_INFO = extern struct {
    MaximumProcessorCount: BYTE,
    ActiveProcessorCount: BYTE,
    Reserved: [38]BYTE,
    ActiveProcessorMask: KAFFINITY,
};

pub const PROCESSOR_RELATIONSHIP = extern struct {
    Flags: BYTE,
    EfficiencyClass: BYTE,
    Reserved: [20]BYTE,
    GroupCount: WORD,
    GroupMask: [1]GROUP_AFFINITY,
};

pub const NUMA_NODE_RELATIONSHIP = extern struct {
    NodeNumber: DWORD,
    Reserved: [20]BYTE,
    GroupMask: GROUP_AFFINITY,
};

pub const CACHE_RELATIONSHIP = extern struct {
    Level: BYTE,
    Associativity: BYTE,
    LineSize: WORD,
    CacheSize: DWORD,
    Type: PROCESSOR_CACHE_TYPE,
    Reserved: [20]BYTE,
    GroupMask: GROUP_AFFINITY,
};

pub const GROUP_RELATIONSHIP = extern struct {
    MaximumGroupCount: WORD,
    ActiveGroupCount: WORD,
    Reserved: [20]BYTE,
    GroupInfo: [1]PROCESSOR_GROUP_INFO,
};

pub const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX = extern struct {
    Relationship: LOGICAL_PROCESSOR_RELATIONSHIP,
    Size: DWORD,
    Value: extern union {
        Processor: PROCESSOR_RELATIONSHIP,
        NumaNode: NUMA_NODE_RELATIONSHIP,
        Cache: CACHE_RELATIONSHIP,
        Group: GROUP_RELATIONSHIP,
    },
};

pub const SE_PRIVILEGE_ENABLED: DWORD = 0x02;
pub const LUID = extern struct {
    LowPart: ULONG,
    HighPart: LONG,
};

pub const LUID_AND_ATTRIBUTES = extern struct {
    Luid: LUID,
    Attributes: DWORD,
};

pub const TOKEN_QUERY: DWORD = 0x08;
pub const TOKEN_ADJUST_PRIVILEGES: DWORD = 0x20;
pub const TOKEN_PRIVILEGES = extern struct {
    PrivilegeCount: DWORD,
    Privileges: [1]LUID_AND_ATTRIBUTES,
};

pub extern "kernel32" fn AcquireSRWLockExclusive(
    srwlock: PSRWLOCK,
) callconv(.Stdcall) void;

pub extern "kernel32" fn ReleaseSRWLockExclusive(
    srwlock: PSRWLOCK,
) callconv(.Stdcall) void;

pub extern "kernel32" fn SetThreadAffinityMask(
    hThread: HANDLE,
    dwThreadAffinityMask: KAFFINITY,
) callconv(.Stdcall) KAFFINITY;

pub extern "kernel32" fn SetThreadGroupAffinity(
    hThread: HANDLE,
    GroupAffinity: *const GROUP_AFFINITY,
    PreviousGroupAffinity: ?*GROUP_AFFINITY,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn GetProcessAffinityMask(
    hProcess: HANDLE,
    lpProcessAffinityMask: *KAFFINITY,
    lpSystemAffinityMask: *KAFFINITY,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn VirtualAllocExNuma(
    hProcess: HANDLE,
    lpAddress: ?LPVOID,
    dwSize: SIZE_T,
    flAllocationType: DWORD,
    flProtect: DWORD,
    nndPreferred: DWORD,
) callconv(.Stdcall) ?PVOID;

pub extern "kernel32" fn GetLogicalProcessorInformationEx(
    RelationshipType: LOGICAL_PROCESSOR_RELATIONSHIP,
    Buffer: ?*SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX,
    ReturnedLength: *DWORD,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn GetNumaHighestNodeNumber(
    HighestNodeNumber: *ULONG,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn GetNumaNodeProcessorMaskEx(
    Node: USHORT,
    ProcessorMask: *GROUP_AFFINITY,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn GetNumaAvailableMemoryNodeEx(
    Node: USHORT,
    AvailableBytes: *ULONGLONG,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn GetLargePageMinimum() callconv(.Stdcall) usize;

pub extern "advapi32" fn OpenProcessToken(
    ProcessHandle: HANDLE,
    DesiredAccess: DWORD,
    TokenHandle: *HANDLE,
) callconv(.Stdcall) BOOL;

pub extern "advapi32" fn LookupPrivilegeValueW(
    lpSystemName: ?[*]const WCHAR,
    lpName: [*c]const WCHAR,
    lpLuid: *LUID,
) callconv(.Stdcall) BOOL;

pub extern "advapi32" fn AdjustTokenPrivileges(
    TokenHandle: HANDLE,
    DisableAllPrivileges: BOOL,
    NewState: *TOKEN_PRIVILEGES,
    BufferLength: DWORD,
    PreviousState: ?*TOKEN_PRIVILEGES,
    ReturnLength: ?*DWORD,
) callconv(.Stdcall) BOOL;