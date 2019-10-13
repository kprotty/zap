const std = @import("std");
const windows = std.os.windows;

const zuma = @import("../../../zap.zig").zuma;
const zync = @import("../../../zap.zig").zync;

var current_process = zync.Lazy(GetCurrentProcess).new();
threadlocal var current_thread = zync.Lazy(GetCurrentThread).new();

pub const CpuAffinity = struct {
    pub fn getNodeCount() usize {
        var node: windows.ULONG = 0;
        if (GetNumaHighestNodeNumber(&node) == windows.TRUE)
            return @intCast(usize, node) + 1;
        return 1;
    }

    pub fn getCpuCount(numa_node: ?usize, only_physical_cpus: bool) zuma.CpuAffinity.TopologyError!usize {
        if (numa_node) |node| {
            var affinity: GROUP_AFFINITY = undefined;
            try getNumaGroupAffinity(&affinity, node, only_physical_cpus);
            return zync.popCount(affinity.Mask);
        }
        var cpu_count: usize = 0;
        try iterateProcessorInfo(RelationProcessorCore, findAffinityCount, &cpu_count, only_physical_cpus);
        return cpu_count;
    }

    pub fn getCpus(self: *zuma.CpuAffinity, numa_node: ?usize, only_physical_cpus: bool) zuma.CpuAffinity.TopologyError!void {
        var affinity: GROUP_AFFINITY = undefined;
        if (numa_node) |node| {
            try getNumaGroupAffinity(&affinity, node, only_physical_cpus);
        } else {
            affinity.Mask = ~KAFFINITY(0);
            try iterateProcessorInfo(RelationProcessorCore, findFirstAffinity, &affinity, only_physical_cpus);
        }
        self.group = affinity.Group;
        self.mask = affinity.Mask;
    }

    /// Find the GROUP_AFFINITY of a NUMA node.
    /// If it only needs logical cpus, calls GetNumaNodeProcessorMaskEx instead to save on allocation
    fn getNumaGroupAffinity(affinity: *GROUP_AFFINITY, numa_node: usize, only_physical_cpus: bool) zuma.CpuAffinity.TopologyError!void {
        if (only_physical_cpus) {
            try iterateProcessorInfo(RelationNumaNode, findNumaGroupAffinity, numa_node, affinity);
        } else if (GetNumaNodeProcessorMaskEx(@truncate(USHORT, numa_node), affinity) == windows.FALSE) {
            return zuma.CpuAffinity.TopologyError.InvalidNode;
        }
    }

    fn findNumaGroupAffinity(
        processor_info: *SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX,
        numa_node: usize,
        affinity: *GROUP_AFFINITY,
    ) bool {
        if (processor_info.Relationship != RelationNumaNode)
            return false;
        if (processor_info.Value.NumaNode.NodeNumber != numa_node)
            return false;
        affinity.* = processor_info.Value.NumaNode.GroupMask;
        return true;
    }

    fn findAffinityCount(
        processor_info: *SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX,
        cpu_count: *usize,
        only_physical_cpus: bool,
    ) bool {
        if (processor_info.Relationship == RelationProcessorCore) {
            std.debug.assert(processor_info.Value.Processor.GroupCount == 1);
            const affinity = processor_info.Value.Processor.GroupMask[0];
            cpu_count.* += if (only_physical_cpus) 1 else zync.popCount(affinity.Mask);
        }
        return false;
    }

    fn findFirstAffinity(
        processor_info: *SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX,
        affinity: *GROUP_AFFINITY,
        only_physical_cpus: bool,
    ) bool {
        // Ensure the processor_info describes a CPU core
        if (processor_info.Relationship != RelationProcessorCore)
            return false;
        std.debug.assert(processor_info.Value.Processor.GroupCount == 1);

        // Get the processor_info's GROUP_AFFINITY, filtering out logical cpu bits if needed
        const processor_affinity = &processor_info.Value.Processor.GroupMask[0];
        if (only_physical_cpus) {
            const physical_cpu = @ctz(KAFFINITY, processor_affinity.Mask) - 1;
            processor_affinity.Mask = KAFFINITY(1) << @truncate(zync.shrType(KAFFINITY), physical_cpu);
        }

        // Update the affinity with the new mask of the current processor_info's GROUP_AFFINITY
        if (affinity.Mask == ~KAFFINITY(0))
            affinity.Group = processor_affinity.Group;
        if (affinity.Group == processor_affinity.Group)
            affinity.Mask |= processor_affinity.Mask;
        return false;
    }

    fn iterateProcessorInfo(
        comptime relationship: LOGICAL_PROCESSOR_RELATIONSHIP,
        comptime found_processor_info: var,
        found_processor_info_args: ...,
    ) zuma.CpuAffinity.TopologyError!void {
        // Find the size in bytes for the process info buffer
        var size: windows.DWORD = 0;
        if (GetLogicalProcessorInformationEx(relationship, null, &size) != windows.FALSE)
            return zuma.CpuAffinity.TopologyError.InvalidResourceAccess;

        // Allocate a correctly sized process info buffer on the process heap
        const heap = windows.kernel32.GetProcessHeap() orelse return zuma.CpuAffinity.TopologyError.InvalidResourceAccess;
        const data = windows.kernel32.HeapAlloc(heap, 0, size) orelse return zuma.CpuAffinity.TopologyError.InvalidResourceAccess;
        defer std.debug.assert(windows.kernel32.HeapFree(heap, 0, data) == windows.TRUE);
        var buffer = @ptrCast([*]u8, data)[0..size];

        // Populate the process info buffer & iterate it
        const data_ptr = @alignCast(@alignOf(*SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX), data);
        var processor_info = @ptrCast(*SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX, data_ptr);
        if (GetLogicalProcessorInformationEx(relationship, processor_info, &size) == windows.FALSE)
            return zuma.CpuAffinity.TopologyError.InvalidResourceAccess;
        while (buffer.len > 0) : (buffer = buffer[processor_info.Size..]) {
            const buffer_ptr = @alignCast(@alignOf(*SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX), buffer.ptr);
            processor_info = @ptrCast(*SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX, buffer_ptr);
            if (found_processor_info(processor_info, found_processor_info_args))
                break;
        }
    }
};

pub const Thread = struct {
    handle: windows.HANDLE,

    var frequency = zync.Lazy(getQPCFrequency).new();
    fn getQPCFrequency() u64 {
        var qpc_frequency: windows.LARGE_INTEGER = undefined;
        std.debug.assert(QueryPerformanceFrequency(&qpc_frequency) == windows.TRUE);
        return @intCast(u64, qpc_frequency) / 1000;
    }

    pub fn now(is_monotonic: bool) u64 {
        if (is_monotonic) {
            var counter: windows.LARGE_INTEGER = undefined;
            std.debug.assert(QueryPerformanceCounter(&counter) == windows.TRUE);
            return @intCast(u64, counter) / frequency.get();
        } else {
            var filetime: FILETIME = undefined;
            GetSystemTimePreciseAsFileTime(&filetime);
            return u64(filetime.dwLowDateTime) | (u64(filetime.dwHighDateTime) << 32);
        }
    }

    pub fn sleep(ms: u32) void {
        Sleep(windows.DWORD(ms));
    }

    pub fn yield() void {
        _ = SwitchToThread();
    }

    pub fn getStackSize(comptime function: var) usize {
        return 0; // windows doesnt allow custom thread stacks
    }

    pub fn spawn(stack: ?[]align(zuma.page_size) u8, comptime function: var, parameter: var) zuma.Thread.SpawnError!@This() {
        const Parameter = @typeOf(parameter);
        const Wrapper = struct {
            extern fn entry(arg: windows.LPVOID) windows.DWORD {
                _ = function(zuma.transmute(Parameter, arg));
                return 0;
            }
        };

        if (stack != null)
            return zuma.Thread.SpawnError.InvalidStack;
        const param = zuma.transmute(*c_void, parameter);
        const commit_stack_size = std.mem.alignForward(@sizeOf(@Frame(function)), zuma.page_size);
        if (windows.kernel32.CreateThread(null, commit_stack_size, Wrapper.entry, param, 0, null)) |handle| {
            return @This(){ .handle = handle };
        } else {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    pub fn join(self: *@This(), timeout_ms: ?u32) void {
        if (self.handle == windows.INVALID_HANDLE_VALUE)
            return;
        _ = windows.kernel32.WaitForSingleObject(self.handle, timeout_ms orelse windows.INFINITE);
        _ = windows.kernel32.CloseHandle(self.handle);
        self.handle = windows.INVALID_HANDLE_VALUE;
    }

    pub fn setAffinity(cpu_affinity: zuma.CpuAffinity) zuma.Thread.AffinityError!void {
        var group_affinity: GROUP_AFFINITY = undefined;
        group_affinity.Mask = cpu_affinity.mask;
        group_affinity.Group = @intCast(u16, cpu_affinity.group);
        std.mem.set(windows.WORD, group_affinity.Reserved[0..], 0);
        if (SetThreadGroupAffinity(current_thread.get(), &group_affinity, null) == windows.FALSE)
            return windows.unexpectedError(windows.kernel32.GetLastError());
    }

    pub fn getAffinity(cpu_affinity: *zuma.CpuAffinity) zuma.Thread.AffinityError!void {
        var group_affinity: GROUP_AFFINITY = undefined;
        if (GetThreadGroupAffinity(current_thread.get(), &group_affinity) == windows.FALSE)
            return windows.unexpectedError(windows.kernel32.GetLastError());
        cpu_affinity.group = group_affinity.Group;
        cpu_affinity.mask = group_affinity.Mask;
    }
};

pub fn getPageSize() ?usize {
    var system_info: windows.SYSTEM_INFO = undefined;
    @memset(@ptrCast([*]u8, &system_info), 0, @sizeOf(@typeOf(system_info)));
    windows.kernel32.GetSystemInfo(&system_info);
    return system_info.dwPageSize;
}

pub fn getHugePageSize() ?usize {
    // Get a token to the current process
    var token: windows.HANDLE = undefined;
    if (OpenProcessToken(current_process.get(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token) == windows.FALSE)
        return null;
    defer _ = windows.kernel32.CloseHandle(token);

    // Use the token to update the process privilege to support huge pages
    var token_privilege: TOKEN_PRIVILEGES = undefined;
    if (LookupPrivilegeValueA(null, c"SeLockMemoryPrivilege", &token_privilege.Privileges[0].Luid) == windows.FALSE)
        return null;
    token_privilege.PrivilegeCount = 1;
    token_privilege.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (AdjustTokenPrivileges(token, windows.FALSE, &token_privilege, 0, null, null) == windows.FALSE)
        return null;

    // Get the system's configured huge page size
    if (windows.kernel32.GetLastError() != ERROR_SUCCESS)
        return null;
    return GetLargePageMinimum();
}

pub fn getNodeSize(numa_node: usize) zuma.NumaError!usize {
    var byte_size: windows.ULONGLONG = undefined;
    if (GetNumaAvailableMemoryNodeEx(@truncate(USHORT, numa_node), &byte_size) == windows.TRUE)
        return @intCast(usize, byte_size);
    return zuma.NumaError.InvalidNode;
}

pub fn map(address: ?[*]u8, bytes: usize, flags: u32, numa_node: ?usize) zuma.MemoryError![]align(zuma.page_size) u8 {
    const protect_flags = getProtectFlags(flags);
    const addr_ptr = @ptrCast(?windows.LPVOID, address);
    const alloc_type = windows.MEM_RESERVE | getAllocType(flags);
    const addr = if (numa_node) |node|
        VirtualAllocExNuma(current_process.get(), addr_ptr, bytes, alloc_type, protect_flags, @intCast(windows.DWORD, node))
    else
        windows.kernel32.VirtualAlloc(addr_ptr, bytes, alloc_type, protect_flags);
    const mem_addr = addr orelse return windows.unexpectedError(windows.kernel32.GetLastError());
    return @ptrCast([*]align(zuma.page_size) u8, @alignCast(zuma.page_size, mem_addr))[0..bytes];
}

pub fn unmap(memory: []u8, numa_node: ?usize) void {
    const addr_ptr = @ptrCast(windows.LPVOID, memory.ptr);
    std.debug.assert(windows.kernel32.VirtualFree(addr_ptr, 0, windows.MEM_RELEASE) == windows.TRUE);
}

pub fn modify(memory: []u8, flags: u32, numa_node: ?usize) zuma.MemoryError!void {
    const addr_ptr = @ptrCast(windows.LPVOID, memory.ptr);
    switch (flags & (zuma.PAGE_COMMIT | zuma.PAGE_DECOMMIT)) {
        zuma.PAGE_COMMIT | zuma.PAGE_DECOMMIT => {
            return zuma.MemoryError.InvalidFlags;
        },
        zuma.PAGE_COMMIT => {
            const alloc_type = getAllocType(flags);
            const protect_flags = getProtectFlags(flags);
            const addr = if (numa_node) |node|
                VirtualAllocExNuma(current_process.get(), addr_ptr, memory.len, alloc_type, protect_flags, @intCast(windows.DWORD, node))
            else
                windows.kernel32.VirtualAlloc(addr_ptr, memory.len, alloc_type, protect_flags);
            if (addr == null)
                return windows.unexpectedError(windows.kernel32.GetLastError());
        },
        zuma.PAGE_DECOMMIT => {
            if (windows.kernel32.VirtualFree(addr_ptr, memory.len, windows.MEM_DECOMMIT) == windows.FALSE)
                return windows.unexpectedError(windows.kernel32.GetLastError());
        },
        else => {
            var old_protect_flags: windows.DWORD = 0;
            if (VirtualProtect(addr_ptr, memory.len, getProtectFlags(flags), &old_protect_flags) == windows.FALSE)
                return windows.unexpectedError(windows.kernel32.GetLastError());
        },
    }
}

fn getAllocType(flags: u32) windows.DWORD {
    var alloc_type: windows.DWORD = 0;
    if ((flags & zuma.PAGE_HUGE) != 0)
        alloc_type |= windows.MEM_LARGE_PAGES;
    if ((flags & zuma.PAGE_COMMIT) != 0)
        alloc_type |= windows.MEM_COMMIT;
    return alloc_type;
}

fn getProtectFlags(flags: u32) windows.DWORD {
    return switch (flags & (zuma.PAGE_EXEC | zuma.PAGE_READ | zuma.PAGE_WRITE)) {
        zuma.PAGE_EXEC => windows.PAGE_EXECUTE,
        zuma.PAGE_READ => windows.PAGE_READONLY,
        zuma.PAGE_READ | zuma.PAGE_EXEC => windows.PAGE_EXECUTE_READ,
        zuma.PAGE_EXEC | zuma.PAGE_WRITE => windows.PAGE_EXECUTE_WRITECOPY,
        zuma.PAGE_WRITE, zuma.PAGE_READ | zuma.PAGE_WRITE => windows.PAGE_READWRITE,
        zuma.PAGE_READ | zuma.PAGE_EXEC | zuma.PAGE_WRITE => windows.PAGE_EXECUTE_READWRITE,
        else => unreachable,
    };
}

pub fn DynamicLibrary(comptime dll_name: [*c]const u8, comptime Imports: type) type {
    return struct {
        var instance = zync.Lazy(loadImports).new();

        pub inline fn get() ?Imports {
            return instance.get();
        }

        fn loadImports() ?Imports {
            var imports: Imports = undefined;
            const module = GetModuleHandleA(dll_name) orelse LoadLibraryA(dll_name) orelse return null;
            inline for (@typeInfo(Imports).Struct.fields) |field| {
                const ptr = windows.kernel32.GetProcAddress(module, (field.name ++ "\x00")[0..].ptr) orelse return null;
                @field(imports, field.name) = @intToPtr(field.field_type, @ptrToInt(ptr));
            }
            return imports;
        }
    };
}

///-----------------------------------------------------------------------------///
///                                API Definitions                              ///
///-----------------------------------------------------------------------------///
const USHORT = u16;
const ERROR_SUCCESS = 0;
const ERROR_INSUFFICIENT_BUFFER = 122;
const KAFFINITY = windows.ULONG_PTR;
const GROUP_AFFINITY = extern struct {
    Mask: KAFFINITY,
    Group: windows.WORD,
    Reserved: [3]windows.WORD,
};

const LOGICAL_PROCESSOR_RELATIONSHIP = windows.DWORD;
const RelationCache: LOGICAL_PROCESSOR_RELATIONSHIP = 2;
const RelationNumaNode: LOGICAL_PROCESSOR_RELATIONSHIP = 1;
const RelationProcessorCore: LOGICAL_PROCESSOR_RELATIONSHIP = 0;
const RelationProcessorPackage: LOGICAL_PROCESSOR_RELATIONSHIP = 3;
const RelationGroup: LOGICAL_PROCESSOR_RELATIONSHIP = 4;
const RelationAll: LOGICAL_PROCESSOR_RELATIONSHIP = 0xffff;

const CacheUnified = PROCESSOR_CACHE_TYPE.CacheUnified;
const CacheInstruction = PROCESSOR_CACHE_TYPE.CacheInstruction;
const CacheData = PROCESSOR_CACHE_TYPE.CacheData;
const CacheTrace = PROCESSOR_CACHE_TYPE.CacheTrace;
const PROCESSOR_CACHE_TYPE = extern enum {
    CacheUnified,
    CacheInstruction,
    CacheData,
    CacheTrace,
};

const PROCESSOR_GROUP_INFO = extern struct {
    MaximumProcessorCount: windows.BYTE,
    ActiveProcessorCount: windows.BYTE,
    Reserved: [38]windows.BYTE,
    ActiveProcessorMask: KAFFINITY,
};

const PROCESSOR_RELATIONSHIP = extern struct {
    Flags: windows.BYTE,
    EfficiencyClass: windows.BYTE,
    Reserved: [20]windows.BYTE,
    GroupCount: windows.WORD,
    GroupMask: [1]GROUP_AFFINITY,
};

const NUMA_NODE_RELATIONSHIP = extern struct {
    NodeNumber: windows.DWORD,
    Reserved: [20]windows.BYTE,
    GroupMask: GROUP_AFFINITY,
};

const CACHE_RELATIONSHIP = extern struct {
    Level: windows.BYTE,
    Associativity: windows.BYTE,
    LineSize: windows.WORD,
    CacheSize: windows.DWORD,
    Type: PROCESSOR_CACHE_TYPE,
    Reserved: [20]windows.BYTE,
    GroupMask: GROUP_AFFINITY,
};

const GROUP_RELATIONSHIP = extern struct {
    MaximumGroupCount: windows.WORD,
    ActiveGroupCount: windows.WORD,
    Reserved: [20]windows.BYTE,
    GroupInfo: [1]PROCESSOR_GROUP_INFO,
};

const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX = extern struct {
    Relationship: LOGICAL_PROCESSOR_RELATIONSHIP,
    Size: windows.DWORD,
    Value: extern union {
        Processor: PROCESSOR_RELATIONSHIP,
        NumaNode: NUMA_NODE_RELATIONSHIP,
        Cache: CACHE_RELATIONSHIP,
        Group: GROUP_RELATIONSHIP,
    },
};

const FILETIME = extern struct {
    dwLowDateTime: windows.DWORD,
    dwHighDateTime: windows.DWORD,
};

const SE_PRIVILEGE_ENABLED: windows.DWORD = 0x02;
const LUID = extern struct {
    LowPart: windows.ULONG,
    HighPart: windows.LONG,
};

const LUID_AND_ATTRIBUTES = extern struct {
    Luid: LUID,
    Attributes: windows.DWORD,
};

const TOKEN_QUERY: windows.DWORD = 0x08;
const TOKEN_ADJUST_PRIVILEGES: windows.DWORD = 0x20;
const TOKEN_PRIVILEGES = extern struct {
    PrivilegeCount: windows.DWORD,
    Privileges: [1]LUID_AND_ATTRIBUTES,
};

extern "kernel32" stdcallcc fn LoadLibraryA(
    lpLibFileName: [*c]const u8,
) ?windows.HMODULE;

extern "kernel32" stdcallcc fn GetModuleHandleA(
    lpModuleName: [*c]const u8,
) ?windows.HMODULE;

extern "kernel32" stdcallcc fn VirtualProtect(
    lpAddress: ?windows.LPVOID,
    dwSize: windows.SIZE_T,
    flNewProtect: windows.DWORD,
    lpflOldProtect: *windows.DWORD,
) windows.BOOL;

extern "kernel32" stdcallcc fn VirtualAllocExNuma(
    hProcess: windows.HANDLE,
    lpAddress: ?windows.LPVOID,
    dwSize: windows.SIZE_T,
    flAllocationType: windows.DWORD,
    flProtect: windows.DWORD,
    nndPreferred: windows.DWORD,
) ?windows.LPVOID;

extern "kernel32" stdcallcc fn GetSystemTimePreciseAsFileTime(
    lpSystemTimeAsFileTime: *FILETIME,
) void;

extern "kernel32" stdcallcc fn QueryPerformanceFrequency(
    lpFrequency: *windows.LARGE_INTEGER,
) windows.BOOL;

extern "kernel32" stdcallcc fn QueryPerformanceCounter(
    lpPerformanceCount: *windows.LARGE_INTEGER,
) windows.BOOL;

extern "kernel32" stdcallcc fn Sleep(dwMilliseconds: windows.DWORD) void;

extern "kernel32" stdcallcc fn SwitchToThread() windows.BOOL;

extern "kernel32" stdcallcc fn GetCurrentProcess() windows.HANDLE;
extern "kernel32" stdcallcc fn GetCurrentThread() windows.HANDLE;

extern "kernel32" stdcallcc fn GetThreadGroupAffinity(
    hThread: windows.HANDLE,
    GroupAffinity: *GROUP_AFFINITY,
) windows.BOOL;

extern "kernel32" stdcallcc fn SetThreadGroupAffinity(
    hThread: windows.HANDLE,
    GroupAffinity: *const GROUP_AFFINITY,
    PreviousGroupAffinity: ?*GROUP_AFFINITY,
) windows.BOOL;

extern "kernel32" stdcallcc fn GetLogicalProcessorInformationEx(
    RelationshipType: LOGICAL_PROCESSOR_RELATIONSHIP,
    Buffer: ?*SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX,
    ReturnedLength: *windows.DWORD,
) windows.BOOL;

extern "kernel32" stdcallcc fn GetNumaHighestNodeNumber(
    HighestNodeNumber: *windows.ULONG,
) windows.BOOL;

extern "kernel32" stdcallcc fn GetNumaNodeProcessorMaskEx(
    Node: USHORT,
    ProcessorMask: *GROUP_AFFINITY,
) windows.BOOL;

extern "kernel32" stdcallcc fn GetNumaAvailableMemoryNodeEx(
    Node: USHORT,
    AvailableBytes: *windows.ULONGLONG,
) windows.BOOL;

extern "kernel32" stdcallcc fn GetLargePageMinimum() usize;

extern "advapi32" stdcallcc fn OpenProcessToken(
    ProcessHandle: windows.HANDLE,
    DesiredAccess: windows.DWORD,
    TokenHandle: *windows.HANDLE,
) windows.BOOL;

extern "advapi32" stdcallcc fn LookupPrivilegeValueA(
    lpSystemName: ?[*]const u8,
    lpName: [*c]const u8,
    lpLuid: *LUID,
) windows.BOOL;

extern "advapi32" stdcallcc fn AdjustTokenPrivileges(
    TokenHandle: windows.HANDLE,
    DisableAllPrivileges: windows.BOOL,
    NewState: *TOKEN_PRIVILEGES,
    BufferLength: windows.DWORD,
    PreviousState: ?*TOKEN_PRIVILEGES,
    ReturnLength: ?*windows.DWORD,
) windows.BOOL;
