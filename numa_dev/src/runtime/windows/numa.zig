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
const windows = @import("./windows.zig");
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
                addr = @ptrToInt(windows.VirtualAllocExNuma(proc, null, bytes, alloc_type, protect, numa_node));
                if (addr == 0)
                    return windows.unexpectedError(windows.kernel32.GetLastError());
            }
        }

        if (addr == 0) {
            addr = @ptrToInt(windows.kernel32.VirtualAlloc(null, bytes, alloc_type, protect));
            if (addr == 0)
                return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        if (@intToPtr(?[*]align(std.mem.page_size) u8, addr)) |memory_ptr|
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
            @typeInfo(usize).Int.bits < 64 or
            std.builtin.single_threaded or
            !isWindowsVersionOrHigher(.win7)
        ) {
            _topology_default[0].cpu_begin = 0;
            _topology_default[0].cpu_end = @intCast(windows.WORD, windows.peb().NumberOfProcessors - 1);
            return error.UseDefaultTopology;
        }

        var length: windows.DWORD = 0;
        const PROC_INFO = windows.SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX;
        const relationship = windows.LOGICAL_PROCESSOR_RELATIONSHIP.RelationNumaNode;
        if (
            (windows.GetLogicalProcessorInformationEx(relationship, null, &length) != windows.FALSE) or
            (windows.kernel32.GetLastError() != .INSUFFICIENT_BUFFER)
        ) {
            return error.InvalidGetProcInfo;
        }

        const heap = windows.kernel32.GetProcessHeap() orelse return error.NoProcessHeap;
        const alignment = std.math.max(@alignOf(PROC_INFO), @alignOf(NumaNode));
        const buf_ptr = windows.kernel32.HeapAlloc(heap, 0, length + alignment) orelse return error.OutOfHeapMemory;
        errdefer std.debug.assert(windows.kernel32.HeapFree(heap, 0, buf_ptr) == windows.FALSE);

        const proc_info_ptr = @ptrCast([*]PROC_INFO, @alignCast(@alignOf(PROC_INFO), buf_ptr));
        if (windows.GetLogicalProcessorInformationEx(relationship, proc_info_ptr, &length) == windows.FALSE)
            return error.InvalidGetProcInfo;
        
        var num_nodes: usize = 0;
        const nodes = @ptrCast([*]NumaNode, @alignCast(@alignOf(NumaNode), proc_info_ptr));

        var info_ptr = @ptrToInt(proc_info_ptr);
        while (length != 0) {
            const proc_info = @intToPtr(*PROC_INFO, info_ptr);
            info_ptr += proc_info.Size;
            length -= proc_info.Size;
            if (proc_info.Relationship != relationship)
                continue;

            const numa_info = proc_info.u.NumaNode;
            const group_affinity = numa_info.GroupMask;
            const numa_node = NumaNode{
                .node_id = @intCast(windows.WORD, numa_info.NodeNumber),
                .cpu_begin = group_affinity.Group * 64,
                .cpu_end = (group_affinity.Group * 64) + (@popCount(usize, group_affinity.Mask) - 1),
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
};