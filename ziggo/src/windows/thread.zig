const std = @import("std");
const windows = @import("./windows.zig");
const Node = @import("./node.zig").Node;

pub const Thread = struct {
    pub const Affinity = struct {
        group: windows.USHORT,
        mask: windows.KAFFINITY,

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

    const WinThread = extern struct {
        stack_ptr: usize,
        stack_size: usize,
        parameter: usize,
        node: *Node,

        fn alloc(
            node: *Node,
            parameter: usize,
            max_stack_size: usize,
        ) ?*WinThread {
            var stack_size = std.mem.alignForward(std.mem.page_size, max_stack_size);
            stack_size = std.math.max(getMinimalStackSize(), stack_size);
            const thread_offset = std.mem.alignForward(stack_size, @alignOf(WinThread));
            
            const memory = node.alloc(std.mem.page_size, thread_offset + @sizeOf(WinThread)) orelse return null;
            const self = @ptrCast(*WinThread, @alignCast(@alignOf(*WinThread), &memory[thread_offset]));
            self.* = WinThread{
                .stack_ptr = @ptrToInt(memory.ptr),
                .stack_size = stack_size,
                .parameter = parameter,
                .node = node,
            };

            return self;
        }

        fn free(self: *WinThread) void {
            const memory_ptr = self.stack_ptr;
            const memory_len = (@ptrToInt(self) + @sizeOf(WinThread)) - memory_ptr;
            const memory = @intToPtr([*]align(std.mem.page_size) u8, memory_ptr)[0..memory_len];
            self.node.free(std.mem.page_size, memory);
        }

        var allocation_granularity: usize = 0;

        fn getMinimalStackSize() usize {
            var local_allocation_granularity = @atomicLoad(usize, &allocation_granularity, .Acquire);
            if (local_allocation_granularity == 0) {
                var sys_info: windows.SYSTEM_INFO = undefined;
                windows.kernel32.GetSystemInfo(&sys_info);
                local_allocation_granularity = sys_info.dwAllocationGranularity;
                @atomicStore(usize, &allocation_granularity, local_allocation_granularity, .Release);
            }
            return local_allocation_granularity;
        }
    };

    pub const Handle = *WinThread;

    threadlocal var thread_handle: ?Handle = null;

    pub fn getCurrentHandle() ?Handle {
        return thread_handle;
    }

    pub fn spawn(
        node: *Node,
        max_stack_size: usize,
        parameter: var,
        comptime entryFn: var,
    ) ?Handle {
        const Parameter = @TypeOf(parameter);
        const Wrapper = struct {
            fn asyncEntry(param: Parameter) callconv(.Async) void {
                _ = @call(.{}, entryFn, .{param});
            }

            fn entry(raw_param: windows.PVOID) callconv(.C) windows.DWORD {
                const win_thread = @ptrCast(*WinThread, @alignCast(@alignOf(*WinThread), raw_param));
                thread_handle = win_thread;

                const param = @intToPtr(Parameter, win_thread.parameter);
                const stack_ptr = @intToPtr([*]align(std.mem.page_size) u8, win_thread.stack_ptr);
                const stack_memory = stack_ptr[0..win_thread.stack_size];

                // TODO: https://github.com/ziglang/zig/issues/4699
                // _ = @call(.{ .stack = stack_memory }, entryFn, .{param});
                _ = @asyncCall(stack_memory, {}, asyncEntry, param);
                return 0;
            }
        };

        const win_thread = WinThread.alloc(
            node,
            @ptrToInt(parameter),
            max_stack_size,
        ) orelse return null;

        const nt_handle = windows.kernel32.CreateThread(
            null,
            WinThread.getMinimalStackSize(),
            Wrapper.entry,
            @ptrCast(windows.PVOID, win_thread),
            windows.STACK_SIZE_PARAM_IS_A_RESERVATION,
            null,
        ) orelse {
            win_thread.free();
            return null;
        };

        windows.CloseHandle(nt_handle);
        return win_thread;
    }

    pub fn join(handle: Handle) void {
        const win_thread = handle;
        win_thread.free();
    }
};