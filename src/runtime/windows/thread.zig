const std = @import("std");
const windows = std.os.windows;
const Node = @import("./executor.zig").Node;

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

    var _is_win_7: usize = 0;

    fn isWindows7OrHigher() bool {
        var is_win7 = @atomicLoad(usize, &_is_win_7, .Monotonic);
        if (is_win7 != 0)
            return is_win7 == 1;

        is_win7 = 2;
        if (IsWindows7OrGreater() != windows.FALSE)
            is_win7 = 1;
        
        @atomicStore(usize, &_is_win_7, is_win7, .Monotonic);
        return is_win7;
    }
    
    handle: windows.HANDLE,
    parameter: usize,
    node: *Node,

    pub fn spawn(
        noalias node: *Node,
        ideal_cpu: ?usize,
        comptime func: anytype,
        parameter: anytype,
    ) !*Thread {
        const ParameterPtr = @TypeOf(parameter);
        const Wrapper = struct {
            fn entry(raw_arg: windows.LPVOID) callconv(.C) windows.DWORD {
                const thread = @ptrCast(*Thread, @alignCast(@alignOf(Thread), raw_arg));
                const stack = self.getBackingMemory();

                const param = @intToPtr(ParameterPtr, thread.parameter);
                const handle = @ptrCast(*core.Thread.Handle, thread);
                _ = @asyncCall(stack, {}, func, .{handle, param});
                
                return 0; 
            }
        };

        const stack_size = node.stack_size;
        const memory = try node.numa_node.alloc(stack_size);
        errdefer node.numa_node.free(memory);

        const thread = @ptrCast(*Thread, @alignCast(@alignOf(Thread), &memory[stack_size - @sizeOf(Thread)]));
        thread.parameter = @intToPtr(parameter);
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

        const cpu_begin = node.numa_node.affinity.cpu_begin;
        const cpu_end = node.numa_node.affinity.cpu_end;
        const mask = blk: {
            var mask: KAFFINITY = 0;
            var cpu = cpu_begin;
            while (cpu <= cpu_end and cpu < usize.bits) : (cpu += 1)
                mask |= @as(usize, 1) << @intCast(std.math.Log2Int(usize), cpu - cpu_begin);
            break :blk mask;
        };

        if (isWindows7OrHigher()) {
            var group_affinity: GROUP_AFFINITY = undefined;
            group_affinity.Group = @intCast(windows.WORD, cpu_begin / 64);
            group_affinity.Mask = mask;
            _ = SetThreadGroupAffinity(thread.handle, &group_affinity, null);

            if (ideal_cpu) |ideal| {
                var proc_num: PROCESSOR_NUMBER = undefined;
                proc_num.Group = @intCast(windows.WORD, ideal / 64);
                proc_num.Number = @intCast(windows.BYTE, ideal % 64);
                _ = SetThreadIdealProcessorEx(thread.handle, &proc_num, null);
            }

        } else {
            _ = SetThreadAffinityMask(thread.handle, mask);
            if (ideal_cpu) |ideal| {
                if (ideal < 64) {
                    _ = SetThreadIdealProcessor(thread.handle, @intCast(windows.DWORD, ideal));
                }
            }
        }

        return thread;
    }

    pub fn join(
        noalias self: *Thread,
    ) void {
        windows.WaitForSingleObjectEx(self.handle, windows.INFINITE, false) catch unreachable;
        windows.CloseHandle(self.handle);
        self.node.numa_node.free(self.getBackingMemory());
    }

    const KAFFINITY = usize;
    const GROUP_AFFINITY = extern struct {
        Mask: KAFFINITY,
        Group: windows.WORD,
        Reserved: [3]windows.WORD,
    };

    const PROCESSOR_NUMBER = extern struct {
        Group: windows.WORD,
        Number: windows.BYTE,
        Reserved: windows.BYTE,
    };

    extern "kernel32" fn IsWindows7OrGreater() callconv(.Stdcall) windows.BOOLEAN;

    extern "kernel32" fn SetThreadAffinityMask(
        hThread: windows.HANDLE,
        affintyMask: KAFFINITY,
    ) callconv(.Stdcall) KAFFINITY;

    extern "kernel32" fn SetThreadGroupAffinity(
        hThread: windows.HANDLE,
        group_affinity: *const GROUP_AFFINITY,
        prev_affinity: ?*GROUP_AFFINITY,
    ) callconv(.Stdcall) windows.BOOL;

    extern "kernel32" fn SetThreadIdealProcessor(
        hThread: windows.HANDLE,
        dwIdealProcessor: windows.DWORD;
    ) callconv(.Stdcall) windows.DWORD;

    extern "kernel32" fn SetThreadIdealProcessorEx(
        hThread: windows.HANDLE,
        lpIdealProcessor: *const PROCESSOR_NUMBER,
        lpPrevIdealProcessor: ?*PROCESSOR_NUMBER,
    ) callconv(.Stdcall) windows.BOOL;
};