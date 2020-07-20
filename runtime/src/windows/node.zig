const std = @import("std");
const windows = @import("./windows.zig");
const Lock = @import("./lock.zig").Lock;

pub const Node = struct {
    pub const Affinity = extern struct {
        mask: windows.KAFFINITY,
        group: windows.USHORT,

        pub fn getCount(self: Affinity) usize {
            return @popCount(windows.KAFFINITY, self.mask);
        }

        pub fn bindCurrentThread(self: Affinity) void {
            if (@sizeOf(usize) == 8 and (comptime windows.isOSVersionOrHigher(.win7))) {
                _ = windows.SetThreadGroupAffinity(
                    windows.kernel32.GetCurrentThread(),
                    &windows.GROUP_AFFINITY{
                        .Mask = self.mask,
                        .Group = self.group,
                        .Reserved = [_]windows.WORD{0} ** 3,
                    },
                    null,
                );
            } else {
                std.debug.assert(self.group == 0);
                _ = windows.SetThreadAffinityMask(
                    windows.kernel32.GetCurrentThread(),
                    self.mask,
                );
            }
        }
    };

    numa_id: windows.DWORD,
    affinity: Affinity,

    pub fn alloc(
        self: Node,
        bytes: usize,
    ) ?[]align(std.mem.page_size) u8 {
        // TODO: Huge page support
        const protect = windows.PAGE_READWRITE;
        const alloc_type = windows.MEM_RESERVE | windows.MEM_COMMIT;
        const addr = blk: {
            if (comptime windows.isOSVersionOrHigher(.vista)) {
                const process = windows.kernel32.GetCurrentProcess();
                break :blk windows.VirtualAllocExNuma(process, null, bytes, alloc_type, protect, self.numa_id);
            } else {
                break :blk windows.kernel32.VirtualAlloc(null, bytes, alloc_type, protect);
            }
        };
        const ptr = addr orelse return null;
        return @ptrCast([*]align(std.mem.page_size) u8, @alignCast(std.mem.page_size, ptr))[0..bytes];
    }

    pub fn free(
        self: Node,
        memory: []align(std.mem.page_size) u8,
    ) void {
        const addr = @ptrCast(windows.LPVOID, memory.ptr);
        windows.VirtualFree(addr, 0, windows.MEM_RELEASE);
    }

    var lock: Lock = Lock{};
    var is_cached: bool = false;
    var cached: []Node = undefined;

    pub fn getTopology() []Node {
        if (@atomicLoad(bool, &is_cached, .Acquire))
            return cached;

        lock.acquire();
        defer lock.release();

        if (!is_cached) {
            cached = fetchTopology() catch default_topology[0..];
            @atomicStore(bool, &is_cached, true, .Release);
        }

        return cached;
    }

    var default_topology = [_]Node{Node{
        .numa_id = 0,
        .affinity = Affinity{
            .group = 0,
            .mask = 1,
        },
    }};

    fn fetchTopology() ![]Node {
        @setCold(true);
        
        // For platforms under windows 7, use the processor mask as the only node affinity
        if (!(comptime windows.isOSVersionOrHigher(.win7))) {
            var process_affinity: windows.KAFFINITY = undefined;
            const status = windows.GetProcessAffinityMask(
                &process_affinity,
                &@as(windows.KAFFINITY, undefined),
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
        const alignment = @alignOf(windows.SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX);
        const ptr = windows.kernel32.HeapAlloc(heap_handle, 0, length + alignment) orelse return error.OutOfMemory;
        const buffer = @intToPtr([*]align(alignment) u8, std.mem.alignForward(@ptrToInt(ptr), alignment))[0..length];
        errdefer std.debug.assert(windows.kernel32.HeapFree(heap_handle, 0, ptr) != 0);

        // Fetch the NumaNode Info into the allocated buffer
        var info = @ptrCast(*windows.SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX, buffer.ptr);
        result = windows.GetLogicalProcessorInformationEx(windows.RelationNumaNode, info, &length);
        if (result != windows.TRUE)
            return error.UnknownGetProcInfoError;

        // Iterate the NumaNode info buffer 
        // while also using it as the storage for the `Node` structs that it creates.
        var num_nodes: usize = 0;
        const node_buffer = @ptrCast([*]Node, buffer.ptr);
        while (@ptrToInt(info) < (@ptrToInt(buffer.ptr) + buffer.len)) {
            defer info = @intToPtr(*windows.SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX, @ptrToInt(info) + info.Size);
            if (info.Relationship != windows.RelationNumaNode)
                continue;
            
            // Read the node info from the buffer before writing the `Node` struct to the buffer.
            // Memory barrier here to prevent the compiler from reordering the info reads & struct writes
            // since they both happen onto the same buffer pointer.
            const node_info = info.Value.NumaNode;
            asm volatile("" ::: "memory");

            defer num_nodes += 1;
            node_buffer[num_nodes] = Node{
                .numa_id = node_info.NodeNumber,
                .affinity = Affinity{
                    .mask = node_info.GroupMask.Mask,
                    .group = node_info.GroupMask.Group,
                },
            };
        }

        return node_buffer[0..num_nodes];
    }
};

