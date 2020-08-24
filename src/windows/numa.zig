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
const isWindowsVersionOrHigher = windows.isWindowsVersionOrHigher;

pub const NumaNode = extern struct {
    node_id: ?u32,
    cpu_begin: u32,
    cpu_end: u32,

    pub fn getHugePageSize() ?usize {
        // TODO: detect windows large pages at runtime
        return null;
    }

    pub fn alloc(self: *NumaNode, bytes: usize) ?[*]align(std.mem.page_size) u8 {
        var addr: usize = 0;
        const protect = windows.PAGE_READWRITE;
        var alloc_type: windows.DWORD = windows.MEM_RESERVE | windows.MEM_COMMIT;

        // try to allocate using huge pages if its supported
        if (getHugePageSize()) |huge_page_size| {
            if (bytes >= huge_page_size)
                alloc_type |= windows.MEM_LARGE_PAGES;
        }

        // first try to allocate on the provided NUMA node if there is one
        if (self.node_id) |numa_node| {
            if (isWindowsVersionOrHigher(.vista)) {
                const proc = windows.kernel32.GetCurrentProcess();
                addr = @ptrToInt(windows.VirtualAllocExNuma(proc, null, bytes, alloc_type, protect, numa_node));
            }
        }

        // if there isn't one or that doesnt work, fallback to UMA page allocation
        if (addr == 0)
            addr = @ptrToInt(windows.kernel32.VirtualAlloc(null, bytes, alloc_type, protect));

        return @intToPtr(?[*]align(std.mem.page_size) u8, addr);
    }

    pub fn free(self: *NumaNode, memory: []align(std.mem.page_size) u8) void {
        windows.VirtualFree(
            @ptrCast(windows.PVOID, memory.ptr),
            @as(windows.DWORD, 0),
            windows.MEM_RELEASE,
        );
    }

    const UNINIT = 0;
    const CACHED = 1;
    const WAITING = 2;

    var cached_state: u32 = UNINIT;
    var cached_topology: []NumaNode = undefined;
    var default_topology: [_]NumaNode{
        NumaNode{
            .numa_id = null,
            .cpu_begin = 0,
            .cpu_end = 0,
        },
    };

    pub fn getTopology() []NumaNode {
        // use the state to determine if the topology is cached.
        // Acquire barrier to ensure we read the valid topology from the initializer thread.
        var state = @atomicLoad(u32, &cached_state, .Acquire);
        while (true) {
            if (state == CACHED)
                return cached_topology;

            // try to queue this thread as a waiter for the cache as its not ready set.
            // Acquire barrier on failure to read valid topology above if written by initializer thread.
            // Acqiure barrier on success since it needs to be at least equal to failure ordering.
            if (@cmpxchgWeak(
                u32,
                &cached_state,
                state,
                state + WAITING,
                .Acquire,
                .Acquire,
            )) |updated_state| {
                state = updated_state;
                continue;
            }

            // wait on the cache state until its initialized
            if (state != UNINIT) {
                const ptr = @ptrCast(*const c_void, &cached_state);
                const status = windows.NtWaitForKeyedEvent(null, ptr, windows.FALSE, null);
                std.debug.assert(status == .SUCCESS);

                // re-loop with an acquire barrier to see the cached_topology writes.
                // next iteration should have state = CACHED
                state = @atomicLoad(u32, &cached_state, .Acquire);
                continue;

            }

            // fetch the system numa topology and store it in the cache.
            cached_topology = fetchTopology() catch default_topology[0..];

            // mark the cache as ready so that threads can read from that instead of waiting.
            // Release barrier to ensure the cached_topology write above is visible to the other threads.
            state = @atomicRmw(u32, &cached_state, .Xchg, CACHED, .Release);

            // wake up any threads that were waiting for the cache to be ready
            while (state >= WAITING) : (state -= WAITING) {
                const ptr = @ptrCast(*const c_void, &cached_state);
                const status = windows.NtReleaseKeyedEvent(null, ptr, windows.FALSE, null);
                std.debug.assert(status == .SUCCESS);
            }

            return cached_topology;
        }
    }

    fn fetchTopology() ![]NumaNode {
        @setCold(true);

        // if GetLogicalProcessorInformationEx isnt supported, read the PEB for the cpu count instead.
        if (
            @typeInfo(usize).Int.bits < 64 or
            std.builtin.single_threaded or
            !isWindowsVersionOrHigher(.win7)
        ) {
            default_topology[0].cpu_end = @intCast(u32, windows.peb().NumberOfProcessors - 1);
            return default_topology[0..];
        }

        // get the amount of bytes (length) needed in order to query the NUMA node topology of the system
        var length: windows.DWORD = 0;
        const PROC_INFO = windows.SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX;
        const relationship = windows.LOGICAL_PROCESSOR_RELATIONSHIP.RelationNumaNode;
        if (
            (windows.GetLogicalProcessorInformationEx(relationship, null, &length) != windows.FALSE) or
            (windows.kernel32.GetLastError() != .INSUFFICIENT_BUFFER)
        ) {
            return error.InvalidGetProcInfo;
        }

        // allocate the (aligned) buffer used to store both the NUMA node topology info 
        // and the NumaNode structs that will be parsed out of it.
        const heap = windows.kernel32.GetProcessHeap() orelse return error.NoProcessHeap;
        const alignment = std.math.max(@alignOf(PROC_INFO), @alignOf(NumaNode));
        const buf_ptr = windows.kernel32.HeapAlloc(heap, 0, length + alignment) orelse return error.OutOfHeapMemory;
        errdefer std.debug.assert(windows.kernel32.HeapFree(heap, 0, buf_ptr) == windows.FALSE);

        // actually fetch the NUMA node topology
        const proc_info_ptr = @ptrCast([*]PROC_INFO, @alignCast(@alignOf(PROC_INFO), buf_ptr));
        if (windows.GetLogicalProcessorInformationEx(relationship, proc_info_ptr, &length) == windows.FALSE)
            return error.InvalidGetProcInfo;
        
        // prepare the buffer to write the NumaNode structs we parse out of it.
        // they share the same memory buffer so read and write order is important
        var num_nodes: usize = 0;
        const nodes = @ptrCast([*]NumaNode, @alignCast(@alignOf(NumaNode), proc_info_ptr));

        // iterate through all the NUMA node info entries
        var info_ptr = @ptrToInt(proc_info_ptr);
        while (length != 0) {
            const proc_info = @intToPtr(*PROC_INFO, info_ptr);
            info_ptr += proc_info.Size;
            length -= proc_info.Size;
            if (proc_info.Relationship != relationship)
                continue;

            // first, read the numa_info from the buffer and construct the parsed NumaNode
            const numa_info = proc_info.u.NumaNode;
            const group_affinity = numa_info.GroupMask;
            const numa_node = NumaNode{
                .node_id = @intCast(windows.WORD, numa_info.NodeNumber),
                .cpu_begin = group_affinity.Group * 64,
                .cpu_end = (group_affinity.Group * 64) + (@popCount(usize, group_affinity.Mask) - 1),
            };

            // then, write the parsed NumaNode into the buffer.
            //
            // memory barrier to ensure that the nodes[] write below is not re-ordered before the numa_info reads above.
            // this is important because they share the same buffer memory so writes before could mess up reads.
            asm volatile("" ::: "memory");
            nodes[num_nodes] = numa_node;
            num_nodes += 1;
        }

        return nodes[0..num_nodes];
    }
};
