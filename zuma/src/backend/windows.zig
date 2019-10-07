const std = @import("std");
const windows = std.os.windows;

const zuma = @import("../../../zap.zig").zuma;
const zync = @import("../../../zap.zig").zync;

pub const CpuSet = struct {
    pub fn getNodeCount() usize {
        var node: windows.ULONG = undefined;
        if (GetNumaHighestNodeNumber(&node) == windows.TRUE)
            return @intCast(usize, node);
        return usize(1);
    }

    pub fn getCpuCount(numa_node: ?usize, only_physical_cpus: bool) zuma.CpuSet.TopologyError!usize {
        if (numa_node) |node| {
            var affinity: GROUP_AFFINITY = undefined;
            try getNumaGroupAffinity(&affinity, node, only_physical_cpus);
            return zync.popCount(affinity.Mask);
        }
        var cpu_count: usize = 0;
        try iterateProcessorInfo(RelationProcessorCore, findAffinityCount, &cpu_count, only_physical_cpus);
        return cpu_count;
    }

    pub fn getCpus(cpu_set: *zuma.CpuSet, numa_node: ?usize, only_physical_cpus: bool) zuma.CpuSet.TopologyError!void {
        var affinity: GROUP_AFFINITY = undefined;
        if (numa_node) |node| {
            affinity = try getNumaGroupAffinity(&affinity, node, only_physical_cpus);
        } else {
            try iterateProcessorInfo(RelationProcessorCore, findFirstAffinity, &affinity, only_physical_cpus);
        }
        cpu_set.group = affinity.Group;
        cpu_set.mask = affinity.Mask;
    }

    /// Find the GROUP_AFFINITY of a NUMA node.
    /// If it only needs logical cpus, calls GetNumaNodeProcessorMaskEx instead to save on allocation
    fn getNumaGroupAffinity(affinity: *GROUP_AFFINITY, numa_node: usize, only_physical_cpus: bool) zuma.CpuSet.TopologyError!void {
        if (only_physical_cpus) {
            try iterateProcessorInfo(RelationNumaNode, findNumaGroupAffinity, numa_node, affinity);
        } else if (GetNumaNodeProcessorMaskEx(@truncate(USHORT, numa_node), affinity) == windows.FALSE) {
            return zuma.CpuSet.CpuError.InvalidNode;
        }
    }

    fn findNumaGroupAffinity(
        processor_info: *const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX,
        numa_node: usize,
        affinity: *GROUP_AFFINITY,
    ) bool {
        if (processor_info.Relationship != RelationNumaNode)
            return false;
        if (usize(processor_info.Value.NumaNode.NodeNumber) != numa_node)
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
    ) zuma.CpuSet.TopologyError!void {
        // Find the size in bytes for the process info buffer
        var size: windows.DWORD = 0;
        if (GetLogicalProcessorInformationEx(relationship, null, &size) != windows.FALSE)
            return zuma.CpuSet.TopologyError.InvalidResourceAccess;

        // Allocate a correctly sized process info buffer on the process heap
        const heap = windows.kernel32.GetProcessHeap() orelse return zuma.CpuSet.TopologyError.InvalidResourceAccess;
        const data = windows.kernel32.HeapAlloc(heap, 0, size) orelse return zuma.CpuSet.TopologyError.InvalidResourceAccess;
        defer std.debug.assert(windows.kernel32.HeapFree(heap, 0, data) == windows.TRUE);
        var buffer = zuma.mem.ptrCast([*]const u8, data)[0..size];

        // Populate the process info buffer & iterate it
        var processor_info = zuma.mem.ptrCast(*const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX, data);
        if (GetLogicalProcessorInformationEx(relationship, processor_info, &size) == windows.FALSE)
            return zuma.CpuSet.TopologyError.InvalidResourceAccess;
        while (buffer.len > 0) : (buffer = buffer[processor_info.Size..]) {
            processor_info = zuma.mem.ptrCast(*const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX, buffer.ptr);
            if (found_processor_info(processor_info, found_processor_info_args))
                break;
        }
    }
};

pub const Thread = struct {
    pub fn now(is_monotonic: bool) u64 {}

    pub fn sleep(ms: u32) void {}

    pub fn yield() void {}

    pub fn getStackSize(comptime function: var) usize {}

    pub fn spawn(stack: ?[]align(zuma.mem.page_size) u8, comptime function: var, parameter: var) zuma.Thread.SpawnError!@This() {}

    pub fn join(self: *@This(), timeout_ms: ?u32) void {}

    pub fn setAffinity(cpu_set: *const CpuSet) zuma.Thread.AffinityError!void {}

    pub fn getAffinity(cpu_set: *CpuSet) zuma.Thread.AffinityError!void {}
};

pub fn getNodeSize(numa_node: usize) zuma.CpuSet.NodeError!usize {
    var byte_size: windows.ULONGLONG = undefined;
    if (GetNumaAvailableMemoryNodeEx(@truncate(USHORT, numa_node), &byte_size) == windows.TRUE)
        return @intCast(usize, byte_size);
    return zuma.CpuSet.NodeError.InvalidNode;
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

extern "kernel32" stdcallcc fn QueryPerformanceFrequency(
    lpFrequency: *windows.LARGE_INTEGER,
) windows.BOOL;

extern "kernel32" stdcallcc fn QueryPerformanceCounter(
    lpPerformanceCount: *windows.LARGE_INTEGER,
) windows.BOOL;

extern "kernel32" stdcallcc fn GetCurrentThread() windows.HANDLE;

extern "kernel32" stdcallcc fn GetThreadGroupAffinity(
    hThread: windows.HANDLE,
    GroupAffinity: *GROUP_AFFINITY,
) windows.BOOL;

extern "kernel32" stdcallcc fn SetThreadGroupAffinity(
    hThread: windows.HANDLE,
    GroupAffinity: *const GROUP_AFFINITY,
    PreviousGroupAffinity: ?*GROUP_AFFINITY,
) DWORD_PTR;

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
