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
const Node = @import("../executor.zig").Node;
const core = @import("../../zap.zig").core.executor;
const isWindowsVersionOrHigher = @import("./version.zig").isWindowsVersionOrHigher;

pub const Thread = struct {
    var alloc_granularity: usize = 0;

    fn getStackAlignment() usize {
        var granularity = @atomicLoad(usize, &alloc_granularity, .Monotonic);
        if (granularity != 0)
            return granularity;

        var system_info: windows.SYSTEM_INFO = undefined;
        windows.kernel32.GetSystemInfo(&system_info);
        granularity = system_info.dwAllocationGranularity;

        @atomicStore(usize, &alloc_granularity, granularity, .Monotonic);
        return granularity;
    }

    pub fn getStackSize(stack_size: usize) usize {
        const stack_align = getStackAlignment();
        return std.mem.alignForward(stack_size, stack_align);
    } 

    fn getBackingMemory(self: *Thread) []align(std.mem.page_size) u8 {
        const stack_size = self.node.stack_size;
        const stack_ptr = @ptrToInt(self) - (stack_size - @sizeOf(Thread));
        return @intToPtr([*]align(std.mem.page_size) u8, stack_ptr)[0..stack_size]; 
    }

    handle: windows.HANDLE,
    parameter: usize,
    node: *Node,

    pub fn spawn(
        noalias node: *Node,
        comptime func: anytype,
        parameter: anytype,
    ) !*Thread {
        const ParameterPtr = @TypeOf(parameter);
        const Wrapper = struct {
            fn entry(raw_arg: windows.LPVOID) callconv(.C) windows.DWORD {
                const thread = @ptrCast(*Thread, @alignCast(@alignOf(Thread), raw_arg));
                const param = @intToPtr(ParameterPtr, thread.parameter);
                const stack = thread.getBackingMemory();
                
                // TODO: https://github.com/ziglang/zig/issues/4699
                _ = @asyncCall(stack, {}, asyncEntry, .{thread, param});
                
                return 0; 
            }

            fn asyncEntry(
                noalias thread: *Thread,
                noalias param: ParameterPtr,
            ) callconv(.Async) void {
                return func(thread, param);
            }
        };

        const stack_size = node.stack_size;
        const memory = try node.numa_node.alloc(stack_size);
        errdefer node.numa_node.free(memory);

        const thread = @ptrCast(*Thread, @alignCast(@alignOf(Thread), &memory[stack_size - @sizeOf(Thread)]));
        thread.parameter = @ptrToInt(parameter);
        thread.node = node;

        const STACK_SIZE_PARAM_IS_A_RESERVATION = 0x10000;
        thread.handle = windows.kernel32.CreateThread(
            null,
            getStackAlignment(),
            Wrapper.entry,
            @ptrCast(windows.PVOID, thread),
            STACK_SIZE_PARAM_IS_A_RESERVATION,
            null,
        ) orelse return error.SpawnError;

        return thread;
    }

    pub fn join(
        noalias self: *Thread,
    ) void {
        windows.WaitForSingleObjectEx(self.handle, windows.INFINITE, false) catch unreachable;
        windows.CloseHandle(self.handle);
        self.node.numa_node.free(self.getBackingMemory());
    }

    pub fn bindCurrentToNodeAffinity(
        noalias node: *Node,
        ideal_cpu: ?usize,
    ) void {
        const thread_handle = windows.kernel32.GetCurrentThread();

        const numa_node = node.numa_node;
        const cpu_begin = numa_node.cpu_begin;
        const cpu_end = numa_node.cpu_end;

        const mask = blk: {
            var mask: windows.KAFFINITY = 0;
            var cpu = cpu_begin;
            while (cpu <= cpu_end and cpu < @typeInfo(usize).Int.bits) : (cpu += 1)
                mask |= @as(usize, 1) << @intCast(std.math.Log2Int(usize), cpu - cpu_begin);
            break :blk mask;
        };

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

        } else {
            _ = windows.SetThreadAffinityMask(thread_handle, mask);
            if (ideal_cpu) |ideal| {
                if (ideal < 64) {
                    _ = windows.SetThreadIdealProcessor(
                        thread_handle,
                        @intCast(windows.DWORD, ideal),
                    );
                }
            }
        }
    }
};