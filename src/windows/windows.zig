// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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

pub const _WIN32_WINNT = extern enum(WORD) {
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

pub const VERSIONHELPERAPI = BOOL;

pub const OSVERSIONINFOEXW = extern struct {
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

pub const VER_BUILDNUMBER = 0x04;
pub const VER_MAJORVERSION = 0x02;
pub const VER_MINORVERSION = 0x01;
pub const VER_PLATFORMID = 0x08;
pub const VER_PRODUCT_TYPE = 0x80;
pub const VER_SERVICEPACKMAJOR = 0x20;
pub const VER_SERVICEPACKMINOR = 0x10;
pub const VER_SUITNAME = 0x40;

pub const VER_EQUAL = 1;
pub const VER_GREATER = 2;
pub const VER_GREATER_EQUAL = 3;
pub const VER_LESS = 4;
pub const VER_LESS_EQUAL = 5;

pub const VER_AND = 6;
pub const VER_OR = 7;

pub const LOGICAL_PROCESSOR_RELATIONSHIP = extern enum(WORD) {
    RelationProcessorCore = 0,
    RelationNumaNode = 1,
    RelationCache = 2,
    RelationProcessorPackage = 3,
    RelationGroup = 4,
    RelationAll = 0xffff,
};

pub const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX = extern struct {
    Relationship: LOGICAL_PROCESSOR_RELATIONSHIP,
    Size: DWORD,
    u: extern union {
        Processor: PROCESSOR_RELATIONSHIP,
        NumaNode: NUMA_NODE_RELATIONSHIP,
        Cache: CACHE_RELATIONSHIP,
        Group: GROUP_RELATIONSHIP,
    }
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
    Reserved1: [20]BYTE,
    GroupMask: GROUP_AFFINITY,
};

pub const CACHE_RELATIONSHIP = extern struct {
    Level: CACHE_LEVEL,
    Associativity: CACHE_ASSOCIATIVITY,
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

pub const PROCESSOR_GROUP_INFO = extern struct {
    MaximumProcessorCount: BYTE,
    ActiveProcessorCount: BYTE,
    Reserved: [38]BYTE,
    ActiveProcessorMask: KAFFINITY,
};

pub const CACHE_LEVEL = extern enum(BYTE) {
    L1 = 1,
    L2 = 2,
    L3 = 3,
};

pub const CACHE_ASSOCIATIVITY = extern enum(BYTE) {
    NONE = 0,
    CACHE_FULLY_ASSOCIATIVE = 0xff,
};

pub const PROCESSOR_CACHE_TYPE = extern enum {
    CacheUnified,
    CacheInstruction,
    CacheData,
    CacheTrace,
};

pub const STACK_SIZE_PARAM_IS_A_RESERVATION = 0x10000;

pub extern "kernel32" fn GetLogicalProcessorInformationEx(
    RelationshipType: LOGICAL_PROCESSOR_RELATIONSHIP,
    Buffer: ?[*]SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX,
    ReturnLength: *DWORD,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn VirtualAllocExNuma(
    hProcess: HANDLE,
    addr: ?PVOID,
    bytes: SIZE_T,
    fAllocType: DWORD,
    fProtect: DWORD,
    numaNodePreferred: DWORD,
) callconv(.Stdcall) ?PVOID;

pub extern "kernel32" fn VerifyVersionInfoW(
    lpVersionInformation: *OSVERSIONINFOEXW,
    dwTypeMask: DWORD,
    dwlConditionMask: ULONGLONG,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn VerSetConditionMask(
    ConditionMask: ULONGLONG,
    TypeMask: DWORD,
    Condition: BYTE,
) callconv(.Stdcall) ULONGLONG;

pub extern "kernel32" fn SetThreadAffinityMask(
    hThread: HANDLE,
    affintyMask: KAFFINITY,
) callconv(.Stdcall) KAFFINITY;

pub extern "kernel32" fn SetThreadGroupAffinity(
    hThread: HANDLE,
    group_affinity: *const GROUP_AFFINITY,
    prev_affinity: ?*GROUP_AFFINITY,
) callconv(.Stdcall) BOOL;

pub extern "kernel32" fn SetThreadIdealProcessor(
    hThread: HANDLE,
    dwIdealProcessor: DWORD,
) callconv(.Stdcall) DWORD;

pub extern "kernel32" fn SetThreadIdealProcessorEx(
    hThread: HANDLE,
    lpIdealProcessor: *const PROCESSOR_NUMBER,
    lpPrevIdealProcessor: ?*PROCESSOR_NUMBER,
) callconv(.Stdcall) BOOL;

pub extern "ntdll" fn NtWaitForKeyedEvent(
    handle: ?HANDLE,
    key: ?windows.PVOID,
    alertable: BOOLEAN,
    timeout: ?*const LARGE_INTEGER, 
) callconv(.Stdcall) NTSTATUS;

pub extern "ntdll" fn NtReleaseKeyedEvent(
    handle: ?HANDLE,
    key: ?windows.PVOID,
    alertable: BOOLEAN,
    timeout: ?*const LARGE_INTEGER, 
) callconv(.Stdcall) NTSTATUS;