const std = @import("std");
const windows = std.os.windows;

const zuma = @import("../../../zap.zig").zuma;
const zync = @import("../../../zap.zig").zync;

pub const CpuSet = struct {
    const Type = KAFFINITY;
    const Bits = @typeInfo(Type).Int.bits;

    affinity: GROUP_AFFINITY,

    pub fn set(self: *@This(), index: usize, is_set: bool) zuma.CpuSet.IndexError!void {
        if (index < Bits * self.affinity.Group or index >= Bits * (self.affinity.Group + 1))
            return zuma.CpuSet.IndexError.InvalidCpu;
        const mask = Type(1) << @truncate(zync.shrType(Type), index % Bits);
        if (is_set) {
            self.affinity.Mask |= mask;
        } else {
            self.affinity.Mask &= ~mask;
        }
    }

    pub fn get(self: @This(), index: usize) zuma.CpuSet.IndexError!bool {
        if (index < Bits * self.affinity.Group or index >= Bits * (self.affinity.Group + 1))
            return zuma.CpuSet.IndexError.InvalidCpu;
        return (self.affinity.Mask & Type(1) << @truncate(zync.shrType(Type), index % Bits)) != 0;
    }

    pub fn count(self: @This()) usize {
        return zync.popCount(self.affinity.Mask);
    }

    pub fn getNodeCount() usize {
        var node: windows.ULONG = undefined;
        if (GetNumaHighestNodeNumber(&node) == windows.TRUE)
            return @intCast(usize, node);
        return usize(1);
    }

    pub fn getNodeSize(numa_node: usize) zuma.CpuSet.NodeError!usize {
        var byte_size: windows.ULONGLONG = undefined;
        if (GetNumaAvailableMemoryNodeEx(@truncate(USHORT, numa_node), &byte_size) == windows.TRUE)
            return @intCast(usize, byte_size);
        return zuma.CpuSet.NodeError.InvalidNode;
    }

    pub fn getCpus(self: *@This(), numa_node: ?usize, only_physical_cpus: bool) zuma.CpuSet.CpuError!void {
        // Set numa node processors
        var populated = false;
        if (numa_node) |node| {
            if (GetNumaNodeProcessorMaskEx(@truncate(USHORT, node), &self.affinity) == windows.FALSE)
                return zuma.CpuSet.CpuError.InvalidNode;
            populated = true;
        }

        // Filter out to only physical processors
        if (only_physical_cpus) {
            // Allocate a buffer for the processor information
            var length: windows.DWORD = 0;
            if (GetLogicalProcessorInformationEx(RelationProcessorCore, null, &length) != windows.FALSE)
                return zuma.CpuSet.CpuError.SystemResourceAccess;
            if (windows.kernel32.GetLastError() != ERROR_INSUFFICIENT_BUFFER)
                return zuma.CpuSet.CpuError.SystemResourceAccess;
            const heap = windows.kernel32.GetProcessHeap() orelse return zuma.CpuSet.CpuError.SystemResourceAccess;
            const data = windows.kernel32.HeapAlloc(heap, 0, length) orelse return zuma.CpuSet.CpuError.SystemResourceAccess;
            defer std.debug.assert(windows.kernel32.HeapFree(heap, 0, data) == windows.TRUE);
            var buffer = zuma.mem.ptrCast([*]u8, data)[0..length];

            // Fetch the processor info & unset those that are logical & set those that are physical
            var processor_info = zuma.mem.ptrCast(*SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX, data);
            if (GetLogicalProcessorInformationEx(RelationProcessorCore, processor_info, &length) == windows.FALSE)
                return zuma.CpuSet.CpuError.SystemResourceAccess;
            self.affinity.Mask = 0;
            while (buffer.len > 0) : (buffer = buffer[processor_info.Size..]) {
                processor_info = zuma.mem.ptrCast(*SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX, buffer.ptr);
                if (processor_info.Relationship == RelationProcessorCore) {
                    const num_groups = processor_info.Value.Processor.GroupCount;
                    for ((processor_info.Value.Processor.GroupMask[0..].ptr)[0..num_groups]) |group| {
                        if (group.Group == self.affinity.Group) {
                            const mask_type = @typeOf(group.Mask);
                            const mask = @ctz(mask_type, group.Mask);
                            self.affinity.Mask |= mask_type(1) << @truncate(zync.shrType(mask_type), mask);
                        }
                    }
                }
            }

            // Get all logical processors ignoring numa configuration
        } else if (!populated) {
            var system_mask: windows.DWORD_PTR = undefined;
            const process_mask = @ptrCast(*windows.DWORD_PTR, &self.affinity.Mask);
            if (GetProcessAffinityMask(GetCurrentProcess(), process_mask, &system_mask) == windows.FALSE)
                return zuma.CpuSet.CpuError.SystemResourceAccess;
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
extern "kernel32" stdcallcc fn GetCurrentProcess() windows.HANDLE;

extern "kernel32" stdcallcc fn GetThreadGroupAffinity(
    hThread: windows.HANDLE,
    GroupAffinity: *GROUP_AFFINITY,
) windows.BOOL;

extern "kernel32" stdcallcc fn SetThreadAffinityMask(
    hThread: windows.HANDLE,
    dwThreadAffinityMask: windows.DWORD_PTR,
) DWORD_PTR;

extern "kernel32" stdcallcc fn GetLogicalProcessorInformationEx(
    RelationshipType: LOGICAL_PROCESSOR_RELATIONSHIP,
    Buffer: ?*SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX,
    ReturnedLength: *windows.DWORD,
) windows.BOOL;

extern "kernel32" stdcallcc fn GetProcessAffinityMask(
    hProcess: windows.HANDLE,
    lpProcessAffinityMask: *windows.DWORD_PTR,
    lpSystemAffinityMask: *windows.DWORD_PTR,
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
