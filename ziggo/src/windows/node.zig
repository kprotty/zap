const std = @import("std");
const windows = @import("./windows.zig");
const Lock = @import("./lock.zig").Lock;
const Affinity = @import("./thread.zig").Thread.Affinity;

pub const Node = struct {
    numa_id: ?windows.DWORD,
    affinity: Affinity,

    pub fn alloc(
        self: Node,
        comptime alignment: u29,
        bytes: usize,
    ) ?[]align(alignment) u8 {
        // TODO: mimalloc-style allocator backed by map()
        const addr = self.map(bytes) orelse return null;
        return @alignCast(alignment, addr)[0..bytes];
    }

    pub fn free(
        self: Node,
        comptime alignment: u29,
        memory: []align(alignment) u8,
    ) void {
        // TODO: mimalloc-style deallocator backed by unmap()
        const addr = @alignCast(std.mem.page_size, memory.ptr);
        return self.unmap(addr, memory.len);
    }

    fn map(
        self: Node,
        bytes: usize,
    ) ?[*]align(std.mem.page_size) u8 {
        // TODO: Huge page support
        const protect = windows.PAGE_READWRITE;
        const alloc_type = windows.MEM_RESERVE | windows.MEM_COMMIT;
        const addr = blk: {
            if (comptime windows.isOSVersionOrHigher(.vista)) {
                if (self.numa_id) |numa_node| {
                    const process = windows.kernel32.GetCurrentProcess();
                    break :blk windows.VirtualAllocExNuma(process, null, bytes, alloc_type, protect, numa_node);
                }
            }
            break :blk windows.kernel32.VirtualAlloc(null, bytes, alloc_type, protect);
        };
        return @ptrCast(?[*]align(std.mem.page_size) u8, @alignCast(std.mem.page_size, addr));
    }

    fn unmap(
        self: Node,
        addr: [*]align(std.mem.page_size) u8,
        bytes: usize,
    ) void {
        const lp_addr = @ptrCast(windows.LPVOID, addr);
        windows.VirtualFree(lp_addr, 0, windows.MEM_RELEASE);
    }

    var has_cached: bool = false;
    var cached_lock: Lock = Lock{};
    var cached_topology: []Node = undefined;
    var default_topology = [_]Node{
        Node{
            .numa_id = null,
            .affinity = Affinity{
                .group = 0,
                .mask = 1,
            },
        },
    };

    pub fn getTopology() []Node {
        if (@atomicLoad(bool, &has_cached, .Acquire))
            return cached_topology;

        cached_lock.acquire();
        defer cached_lock.release();

        if (@atomicLoad(bool, &has_cached, .Acquire))
            return cached_topology;

        cached_topology = getSystemTopology() catch default_topology[0..];
        @atomicStore(bool, &has_cached, true, .Release);
        return cached_topology;
    }

    fn getSystemTopology() ![]Node {
        @setCold(true);

        // For platforms under windows 7, use the processor mask as the only node affinity
        if (!(comptime windows.isOSVersionOrHigher(.win7))) {
            var system_affinity: windows.KAFFINITY = undefined;
            var process_affinity: windows.KAFFINITY = undefined;
            const status = windows.GetProcessAffinityMask(
                &process_affinity,
                &system_affinity,
            );
            if (status == windows.TRUE)
                default_topology[0].affinity.mask = process_affinity;
            return default_topology[0..];
        }

        // Get the amount of bytes to allocate fo the NumaNode Info
        var length: windows.DWORD = 0;
        var result = windows.GetLogicalProcessorInformationEx(windows.RelationNumaNode, null, &length);
        if ((result != windows.FALSE) or (windows.kernel32.GetLastError() != .INSUFFICIENT_BUFFER))
            return error.UnknownGetProcInfoLength;

        // Allocate the aligned buffer for the NumaNode Info
        const heap_handle = windows.kernel32.GetProcessHeap() orelse return error.NoProcHeap;
        const alignment = std.math.max(@alignOf(Node), @alignOf(windows.SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX));
        const ptr = windows.kernel32.HeapAlloc(heap_handle, 0, length + alignment) orelse return error.OutOfMemory;
        errdefer std.debug.assert(windows.kernel32.HeapFree(heap_handle, 0, ptr) != 0);

        const buffer_ptr = std.mem.alignForward(@ptrToInt(ptr), alignment);
        const buffer_len = (@ptrToInt(ptr) + length + alignment) - buffer_ptr;
        const buffer = @intToPtr([*]align(alignment) u8, buffer_ptr)[0..buffer_len];
       
        // Fetch the NumaNode Info into the allocated buffer
        const InfoPtr = *align(alignment) windows.SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX;
        var info = @ptrCast(InfoPtr, buffer.ptr);
        result = windows.GetLogicalProcessorInformationEx(windows.RelationNumaNode, info, &length);
        if (result != windows.TRUE)
            return error.UnknownGetProcInfoError;

        // Iterate the NumaNode info buffer 
        // while also using it as the storage for the `Node` structs that it creates.
        var num_nodes: usize = 0;
        const node_buffer = @ptrCast([*]Node, buffer.ptr);
        while (length != 0) {
            const size = info.Size;
            defer {
                info = @intToPtr(InfoPtr, @ptrToInt(info) + size);
                length -= size;
            }
            if (info.Relationship != windows.RelationNumaNode)
                continue;
            
            // Read the node info from the buffer before writing the `Node` struct to the buffer.
            // Memory barrier here to prevent the compiler from reordering the info reads & struct writes
            // since they both happen onto the same buffer pointer.
            comptime std.debug.assert(@sizeOf(Node) <= @sizeOf(@TypeOf(info.Value.NumaNode)));
            const node_info = info.Value.NumaNode;
            asm volatile("" ::: "memory");
            
            defer num_nodes += 1;
            node_buffer[num_nodes] = Node{
                .numa_id = node_info.NodeNumber,
                .affinity = Affinity{
                    .group = node_info.GroupMask.Group,
                    .mask = node_info.GroupMask.Mask,
                },
            };
        }

        return node_buffer[0..num_nodes];
    }
};
