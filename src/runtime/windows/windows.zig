const std = @import("std");

pub usingnamespace std.os.windows;

pub const KAFFINITY = usize;
pub const GROUP_AFFINITY = extern struct {
    Mask: KAFFINITY,
    Group: WORD,
    Reserved: [3]WORD,
};

pub const PROCESSOR_NUMBER = extern struct {
    Group: WORD,
    Number: BYTE,
    Reserved: BYTE,
};

const _WIN32_WINNT = extern enum(WORD) {
    NT4 = 0x0400,
    WIN2K = 0x0500,
    WINXP = 0x0501,
    WSO3 = 0x0502,
    WIN6 = 0x0600,
    VISTA = 0x0600,
    WS08 = 0x0600,
    LONGHORN = 0x0600,
    WIN7 = 0x0601,
    WIN8 = 0x0602,
    WINBLUE = 0x0603,
    WINTHRESHOLD = 0x0A00,
    WIN10 = 0x0A00,
};

const VERSIONHELPERAPI = BOOL;

const OSVERSIONINFOEXW = extern struct {
    dwOSVersionInfoSize: DWORD,
    dwMajorVersion: DWORD,
    dwMinorVersion: DWORD,
    dwBuildNumber: DWORD,
    dwPlatformId: DWORD,
    szCSDVersion: [128]CHAR,
    wServicePackMajor: WORD,
    wServicePackMinor: WORD,
    wSuiteMask: WORD,
    wProductType: BYTE,
    wReserved: BYTE,
};

const VER_BUILDNUMBER = 0x04;
const VER_MAJORVERSION = 0x02;
const VER_MINORVERSION = 0x01;
const VER_PLATFORMID = 0x08;
const VER_PRODUCT_TYPE = 0x80;
const VER_SERVICEPACKMAJOR = 0x20;
const VER_SERVICEPACKMINOR = 0x10;
const VER_SUITNAME = 0x40;

const VER_EQUAL = 1;
const VER_GREATER = 2;
const VER_GREATER_EQUAL = 3;
const VER_LESS = 4;
const VER_LESS_EQUAL = 5;

const VER_AND = 6;
const VER_OR = 7;

const LOGICAL_PROCESSOR_RELATIONSHIP = extern enum(WORD) {
    RelationProcessorCore = 0,
    RelationNumaNode = 1,
    RelationCache = 2,
    RelationProcessorPackage = 3,
    RelationGroup = 4,
    RelationAll = 0xffff,
};

const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX = extern struct {
    Relationship: LOGICAL_PROCESSOR_RELATIONSHIP,
    Size: DWORD,
    u: extern union {
        Processor: PROCESSOR_RELATIONSHIP,
        NumaNode: NUMA_NODE_RELATIONSHIP,
        Cache: CACHE_RELATIONSHIP,
        Group: GROUP_RELATIONSHIP,
    }
};

const PROCESSOR_RELATIONSHIP = extern struct {
    Flags: BYTE,
    EfficiencyClass: BYTE,
    Reserved: [20]BYTE,
    GroupCount: WORD,
    GroupMask: [1]GROUP_AFFINITY,
};

const NUMA_NODE_RELATIONSHIP = extern struct {
    NodeNumber: DWORD,
    Reserved1: [20]BYTE,
    GroupMask: GROUP_AFFINITY,
};

const CACHE_RELATIONSHIP = extern struct {
    Level: CACHE_LEVEL,
    Associativity: CACHE_ASSOCIATIVITY,
    LineSize: WORD,
    CacheSize: DWORD,
    Type: PROCESSOR_CACHE_TYPE,
    Reserved: [20]BYTE,
    GroupMask: GROUP_AFFINITY,
};

const GROUP_RELATIONSHIP = extern struct {
    MaximumGroupCount: WORD,
    ActiveGroupCount: WORD,
    Reserved: [20]BYTE,
    GroupInfo: [1]PROCESSOR_GROUP_INFO,
};

const PROCESSOR_GROUP_INFO = extern struct {
    MaximumProcessorCount: BYTE,
    ActiveProcessorCount: BYTE,
    Reserved: [38]BYTE,
    ActiveProcessorMask: KAFFINITY,
};

const CACHE_LEVEL = extern enum(BYTE) {
    L1 = 1,
    L2 = 2,
    L3 = 3,
};

const CACHE_ASSOCIATIVITY = extern enum(BYTE) {
    NONE = 0,
    CACHE_FULLY_ASSOCIATIVE = 0xff,
};

const PROCESSOR_CACHE_TYPE = extern enum {
    CacheUnified,
    CacheInstruction,
    CacheData,
    CacheTrace,
};

extern "kernel32" fn GetLogicalProcessorInformationEx(
    RelationshipType: PROCESSOR_RELATIONSHIP,
    Buffer: ?[*]NUMA_INFO_EX,
    ReturnLength: *DWORD,
) callconv(.Stdcall) BOOL;

extern "kernel32" fn VirtualAllocExNuma(
    hProcess: HANDLE,
    addr: ?PVOID,
    bytes: SIZE_T,
    fAllocType: DWORD,
    fProtect: DWORD,
    numaNodePreferred: DWORD,
) callconv(.Stdcall) ?PVOID;

extern "kernel32" fn VerifyVersionInfoW(
    lpVersionInformation: *OSVERSIONINFOEXW,
    dwTypeMask: DWORD,
    dwlConditionMask: ULONGLONG,
) callconv(.Stdcall) BOOL;

extern "kernel32" fn VerSetConditionMask(
    ConditionMask: ULONGLONG,
    TypeMask: DWORD,
    Condition: BYTE,
) callconv(.Stdcall) ULONGLONG,

extern "kernel32" fn SetThreadAffinityMask(
    hThread: HANDLE,
    affintyMask: KAFFINITY,
) callconv(.Stdcall) KAFFINITY;

extern "kernel32" fn SetThreadGroupAffinity(
    hThread: HANDLE,
    group_affinity: *const GROUP_AFFINITY,
    prev_affinity: ?*GROUP_AFFINITY,
) callconv(.Stdcall) BOOL;

extern "kernel32" fn SetThreadIdealProcessor(
    hThread: HANDLE,
    dwIdealProcessor: DWORD,
) callconv(.Stdcall) DWORD;

extern "kernel32" fn SetThreadIdealProcessorEx(
    hThread: HANDLE,
    lpIdealProcessor: *const PROCESSOR_NUMBER,
    lpPrevIdealProcessor: ?*PROCESSOR_NUMBER,
) callconv(.Stdcall) BOOL;