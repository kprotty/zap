const std = @import("std");
const windows = std.os.windows;
const isWindowsVersionOrHigher = @import("./version.zig").isWindowsVersionOrHigher;

pub const NumaNode = struct {
    node_id: ?windows.WORD,
    cpu_begin: windows.WORD,
    cpu_end: windows.WORD,

    pub fn supportsHugePages() bool {
        // TODO: detect windows large pages at runtime
        return false;
    }

    pub const AllocError = std.mem.Allocator.Error || std.os.UnexpectedError; 

    pub fn alloc(
        noalias self: *NumaNode,
        bytes: usize,
    ) AllocError![]align(std.mem.page_size) u8 {
        var addr: usize = 0;
        const protect = windows.PAGE_READWRITE;
        var alloc_type: windows.DWORD = windows.MEM_RESERVE | windows.MEM_COMMIT;
        if (supportsHugePages())
            alloc_type |= windows.MEM_LARGE_PAGES;

        if (self.node_id) |numa_node| {
            if (isWindowsVersionOrHigher(.vista)) {
                const proc = windows.kernel32.GetCurrentProcess();
                addr = @ptrToInt(VirtualAllocExNuma(proc, null, bytes, alloc_type, protect, numa_node));
                if (addr == 0)
                    return windows.unexpectedError(windows.kernel32.GetLastError());
            }
        }

        if (addr == 0) {
            addr = @ptrToInt(windows.kernel32.VirtualAlloc(null, bytes, alloc_type, protect));
            if (addr == 0)
                return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        if (@intToPtr([*]align(std.mem.page_size) u8, addr)) |memory_ptr|
            return memory_ptr[0..bytes];
        return std.mem.Allocator.Error.OutOfMemory;
    }

    pub fn free(
        noalias self: *NumaNode,
        memory: []align(std.mem.page_size) u8,
    ) void {
        windows.VirtualFree(
            @ptrCast(windows.PVOID, memory.ptr),
            @as(windows.DWORD, 0),
            windows.MEM_RELEASE,
        );
    }

    const TopologyState = enum(usize) {
        uninit,
        creating,
        cached,
    };

    var _topology: []NumaNode = undefined;
    var _topology_state: TopologyState = .uninit;
    var _topology_event = std.ResetEvent.init();
    var _topology_default = [_]NumaNode{
        NumaNode{
            .node_id = null,
            .cpu_begin = 0,
            .cpu_end = 0,
        },
    };

    pub fn getTopology() []NumaNode {
        if (@atomicLoad(TopologyState, &_topology_state, .Acquire) != .cached)
            return getTopologySlow();
        return _topology;
    }

    fn getTopologySlow() []NumaNode {
        @setCold(true);

        if (@cmpxchgStrong(
            TopologyState,
            &_topology_state,
            .uninit,
            .creating,
            .Acquire,
            .Acquire,
        )) |changed_state| {
            if (changed_state != .cached)
                _topology_event.wait();
            return _topology;
        }

        _topology = getSystemTopology() catch _topology_default[0..];
        @atomicStore(TopologyState, &_topology_state, .cached, .Release);
        return _topology;
    }

    fn getSystemTopology() ![]NumaNode {
        if (
            usize.bits < 64 or
            std.builtin.single_threaded or
            !isWindowsVersionOrHigher(.win7)
        ) {
            _topology_default[0].cpu_begin = 0;
            _topology_default[0].cpu_end = @intCast(windows.WORD, windows.peb().NumberOfProcessors - 1);
            return error.UseDefaultTopology;
        }

        var length: windows.DWORD = 0;
        const relationship = PROCESSOR_RELATIONSHIP.NumaNode;
        if (
            (GetLogicalProcessorInformationEx(relationship, null, &length) != windows.FALSE) or
            (windows.kernel32.GetLastError() != .INSUFFICIENT_BUFFER)
        ) {
            return error.InvalidGetProcInfo;
        }

        const heap = windows.kernel32.GetProcessHeap() orelse return error.NoProcessHeap;
        const alignment = std.math.max(@alignOf(NUMA_INFO_EX), @alignOf(Node));
        const buf_ptr = windows.kernel32.HeapAlloc(heap, 0, length + alignment) orelse return error.OutOfHeapMemory;
        errdefer if (windows.kernel32.HeapFree(heap, 0, buf_ptr) == windows.FALSE) {
            _ = windows.unexpectedError(windows.kernel32.GetLastError()); 
        };

        const numa_info_ptr = @ptrCast([*]NUMA_INFO_EX, @alignCast(@alignOf(NUMA_INFO_EX), buf_ptr));
        if (GetLogicalProcessorInformationEx(relationship, numa_info_ptr, &length) == windows.FALSE)
            return error.InvalidGetProcInfo;
        
        var num_nodes: usize = 0;
        const nodes = @ptrCast([*]NumaNode, @alignCast(@alignOf(NumaNode), numa_info_ptr));

        var info_ptr = @ptrToInt(numa_info_ptr);
        while (length != 0) {
            const numa_info = @intToPtr(*NUMA_INFO_EX, info_ptr);
            info_ptr += numa_info.Size;
            length -= numa_info.Size;
            if (numa_info.Relationship != relationship)
                continue;

            const numa_node = NumaNode{
                .node_id = @intCast(windows.WORD, numa_info.NodeNumber),
                .cpu_begin = numa_info.Group * 64,
                .cpu_end = (numa_info.Group * 64) + @popCount(usize, numa_info.Mask),
            };

            // memory barrier to ensure that the nodes[] write below
            // is not re-ordered before the numa_info reads above.
            // this is important because they share the same buffer memory.
            asm volatile("" ::: "memory");
            nodes[num_nodes] = numa_node;
            num_nodes += 1;
        }

        return nodes[0..num_nodes];
    }

    const PROCESSOR_RELATIONSHIP = extern enum(windows.WORD) {
        NumaNode = 1,
    };

    const NUMA_INFO_EX = extern struct {
        Relationship: PROCESSOR_RELATIONSHIP,
        Size: windows.DWORD,
        NodeNumer: windows.DWORD,
        Reserved1: [20]windows.BYTE,
        Mask: usize,
        Group: windows.WORD,
        Reserved2: [3]windows.DWORD,
    };

    extern "kernel32" fn GetLogicalProcessorInformationEx(
        RelationshipType: PROCESSOR_RELATIONSHIP,
        Buffer: ?[*]NUMA_INFO_EX,
        ReturnLength: *windows.DWORD,
    ) callconv(.Stdcall) windows.BOOL;
};