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
const NumaNode = @import("./numa.zig").NumaNode;
const isWindowsVersionOrHigher = @import("./version.zig").isWindowsVersionOrHigher;

pub const Thread = extern struct {
    ideal_cpu: u32,
    base_offset: u32,
    handle: windows.HANDLE,
    numa_node: *NumaNode,
    parameter: usize,

    var _alloc_granularity: u32 = 0;

    /// Fetches the virtual page allocation granularity
    fn getStackAlignment() u32 {
        const alloc_granularity = @atomicLoad(u32, &_alloc_granularity, .Monotonic);
        if (alloc_granularity == 0)
            return getStackAlignmentSlow();
        return alloc_granularity;
    }

    fn getStackAlignmentSlow() u32 {
        @setCold(true);

        var system_info: windows.SYSTEM_INFO = undefined;
        windows.kernel32.GetSystemInfo(&system_info);

        const alloc_granularity = system_info.dwAllocationGranuarity;
        @atomicStore(u32, &_alloc_granularity, alloc_granularity, .Monotonic);
        return alloc_granularity;
    }

    /// Return the page allocated memory that this Thread is stored in
    fn getMemory(self: *Thread) []align(std.os.page_size) u8 {
        const base_ptr = @ptrToInt(self) - self.base_offset;
        const base_end = @ptrToInt(self) + @sizeOf(Thread);
        
        const memory_len = base_end - base_ptr;
        const memory_ptr = @intToPtr([*]align(std.os.page_size) u8, base_ptr);
        return memory_ptr[0..memory_len];
    }

    // Return the stack memory that the Thread was allocated with 
    fn getStackMemory(self: *Thread) []align(std.os.page_size) u8 {
        const base_ptr = @ptrToInt(self) - self.base_offset;
        const memory_ptr = @intToPtr([*]align(std.os.page_size) u8, base_ptr);
        return memory_ptr[0..self.base_offset]; 
    }

    pub fn spawn(
        numa_node: *NumaNode,
        stack_size: u32,
        ideal_cpu: ?u32,
        parameter: usize,
        comptime entryPointFn: fn(*Thread, usize) void,
    ) ?*Thread {
        const Wrapper = struct {
            fn entryPoint(raw_arg: windows.LPVOID) callconv(.C) windows.DWORD {
                const self = @ptrCast(*Thread, @alignCast(@alignOf(Thread), raw_arg));
                self.bindAffinity();
                _ = @asyncCall(thread.getStackMemory(), {}, asyncEntryPoint, .{thread});
                return 0;
            }

            // TODO: https://github.com/ziglang/zig/issues/4699
            fn asyncEntryPoint(self: *Thread) callconv(.Async) void {
                _ = entryPointFn(self, self.parameter);
            }
        };

        // allocate the memory for both the stack and the Thread on the provided numa node
        const stack_align = getStackAlignment();
        const stack_bytes = std.math.max(stack_align, std.mem.alignForward(stack_size, stack_align));
        const memory: [*]align(std.mem.page_size) u8 = numa_node.alloc(stack_bytes) orelse return null;

        // initialize the allocated thread pointer
        const base_offset = stack_bytes - @sizeOf(Thread);
        const thread = @ptrCast(*Thread, @alignCast(@alignOf(Thread), &memory[base_offset]));
        thread.* = Thread{
            .ideal_cpu = if (ideal_cpu) |i| (i + 1) else 0,
            .base_offset = base_offset,
            .handle = undefined,
            .numa_node = numa_node,
            .parameter = parameter,
        };

        // try to spawn an OS thread for the allocated Thread.
        //
        // Windows automatically allocates a thread stack, so we use the stack_align to specify the size of it.
        // The smallest virtual page allocation windows does is the allocation granularity (which is the stack alignment).
        //
        // In the thread entry point, we switch to the stack we allocated instead
        // so the size of the Windows allocated thread stack doesn't matter much.
        thread.handle = windows.kernel32.CreateThread(
            null,
            stack_align,
            Wrapper.entryPoint,
            @ptrCast(windows.PVOID, thread),
            windows.STACK_SIZE_PARAM_IS_A_RESERVATION,
            null
        ) orelse {
            numa_node.free(thread.getMemory());
            return null;
        };

        return thread;
    }

    /// Waits for the thread routine to complete 
    /// then deallocates the backing memory for the Thread.
    pub fn join(self: *Thread) void {
        windows.WaitForSingleObjectEx(self.handle, windows.INFINITE, false) catch unreachable;
        windows.CloseHandle(self.handle);
        self.numa_node.free(self.getMemory());
    }

    /// Bind the CPU affinify of the provided Thread to that of its spawned NUMA node.
    fn bindAffinity(self: *Thread) void {
        const thread_handle = self.handle;
        const ideal_cpu = switch (self.ideal_cpu) {
            0 => null,
            else => |ideal_cpu| ideal_cpu - 1,
        };

        const cpu_begin = self.numa_node.cpu_begin;
        const cpu_end = self.numa_node.cpu_end;

        // create a bitmask from numa node cpu range
        const mask = blk: {
            var mask: windows.KAFFINITY = 0;
            var cpu = cpu_begin;
            while (cpu <= cpu_end and cpu < @typeInfo(usize).Int.bits) : (cpu += 1)
                mask |= @as(usize, 1) << @intCast(std.math.Log2Int(usize), cpu - cpu_begin);
            break :blk mask;
        };

        // use thread groups and larger ideal processor counts if supported.
        if (isWindowsVersionOrHigher(.win7)) {
            var group_affinity: windows.GROUP_AFFINITY = undefined;
            group_affinity.Group = @intCast(windows.WORD, cpu_begin / 64);
            group_affinity.Mask = mask;
            _ = windows.SetThreadGroupAffinity(
                thread_handle,
                &group_affinity,
                null,
            );

            if (ideal_cpu) |ideal| {
                var proc_num: windows.PROCESSOR_NUMBER = undefined;
                proc_num.Group = @intCast(windows.WORD, ideal / 64);
                proc_num.Number = @intCast(windows.BYTE, ideal % 64);
                _ = windows.SetThreadIdealProcessorEx(
                    thread_handle,
                    &proc_num,
                    null,
                );
            }

        // if not, fallback to using a single bitmask for the cpu affinity
        } else {
            _ = windows.SetThreadAffinityMask(thread_handle, mask);
            if (ideal_cpu) |ideal| {
                _ = windows.SetThreadIdealProcessor(
                    thread_handle,
                    @intCast(windows.DWORD, ideal),
                );
            }
        }
    }
};

