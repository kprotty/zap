const std = @import("std");
const windows = std.os.windows;

const zuma = @import("../../../zap.zig").zuma;
const zync = @import("../../../zap.zig").zync;

pub const CpuAffinity = struct {
    pub fn getNodeCount() usize {
        var node: windows.ULONG = undefined;
        if (GetNumaHighestNodeNumber(&node) == windows.TRUE)
            return @intCast(usize, node);
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
            affinity = try getNumaGroupAffinity(&affinity, node, only_physical_cpus);
        } else {
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
            return zuma.CpuAffinity.CpuError.InvalidNode;
        }
    }

    fn findNumaGroupAffinity(
        processor_info: *const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX,
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
        processor_info: *const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX,
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
        processor_info: *const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX,
        affinity: *?GROUP_AFFINITY,
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
        if (affinity.*) |current_affinity| {
            if (processor_affinity.Group != current_affinity.Group)
                return false;
            processor_affinity.Mask |= current_affinity.Mask;
        }
        affinity.* = processor_affinity.*;
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
        var buffer = zuma.ptrCast([*]const u8, data)[0..size];

        // Populate the process info buffer & iterate it
        var processor_info = zuma.ptrCast(*const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX, data);
        if (GetLogicalProcessorInformationEx(relationship, processor_info, &size) == windows.FALSE)
            return zuma.CpuAffinity.TopologyError.InvalidResourceAccess;
        while (buffer.len > 0) : (buffer = buffer[processor_info.Size..]) {
            processor_info = zuma.ptrCast(*const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX, buffer.ptr);
            if (found_processor_info(processor_info, found_processor_info_args))
                break;
        }
    }
};

pub const Thread = struct {
    handle: windows.HANDLE,

    var frequency = zync.Lazy(getQPCFrequency).new();
    fn getQPCFrequency() windows.LARGE_INTEGER {
        var qpc_frequency: windows.LARGE_INTEGER = undefined;
        if (QueryPerformanceFrequency(&qpc_frequency) == windows.TRUE)
            return qpc_frequency;
        return windows.LARGE_INTEGER(1000000); // assume nanosecond frequency
    }

    pub fn now(is_monotonic: bool) u64 {
        if (is_monotonic) {
            var counter: windows.LARGE_INTEGER = undefined;
            std.debug.assert(QueryPerformanceCounter(&counter) == windows.TRUE);
            return @intCast(u64, @divFloor(counter, frequency.get()));
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
            return @This() { .handle = handle };
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
        var group_affinity = GROUP_AFFINITY {
            .Group = @intCast(u16, cpu_affinity.group),
            .Mask = cpu_affinity.mask,
            .Reserved = undefined,
        };
        if (SetThreadGroupAffinity(GetCurrentThread(), &group_affinity, null) == windows.FALSE)
            return windows.unexpectedError(windows.kernel32.GetLastError());
    }

    pub fn getAffinity(cpu_affinity: *zuma.CpuAffinity) zuma.Thread.AffinityError!void {
        var group_affinity: GROUP_AFFINITY = undefined;
        if (GetThreadGroupAffinity(GetCurrentThread(), &group_affinity) == windows.FALSE)
            return windows.unexpectedError(windows.kernel32.GetLastError());
        cpu_affinity.group = group_affinity.Group;
        cpu_affinity.mask = group_affinity.Mask;
    }
};

pub fn getNodeSize(numa_node: usize) zuma.NumaError!usize {
    var byte_size: windows.ULONGLONG = undefined;
    if (GetNumaAvailableMemoryNodeEx(@truncate(USHORT, numa_node), &byte_size) == windows.TRUE)
        return @intCast(usize, byte_size);
    return zuma.NumaError.InvalidNode;
}

///-----------------------------------------------------------------------------///
///                                API Definitions                              ///
///-----------------------------------------------------------------------------///
const USHORT = u16;
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
