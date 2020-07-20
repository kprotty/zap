const std = @import("std");
const windows = @import("./windows.zig");
const Node = @import("./node.zig").Node;

pub const Thread = struct {
    pub const Info = extern struct {
        stack_size: usize,
        parameter: usize,
        numa_node: *Node,
        handle: windows.HANDLE,

        fn getStack(self: *Info) []align(std.mem.page_size) u8 {
            const ptr = @ptrToInt(self) - self.stack_size;
            const stack_ptr = @intToPtr([*]align(std.mem.page_size) u8, ptr);
            return stack_ptr[0..self.stack_size];
        }

        fn alloc(numa_node: *Node, max_stack_size: usize) ?*Info {
            const stack_size = std.mem.alignForward(max_stack_size, std.mem.page_size);
            const memory = numa_node.alloc(stack_size + @sizeOf(Info)) orelse return null;

            const info = @ptrCast(*Info, @alignCast(@alignOf(Info), memory.ptr + stack_size));
            info.stack_size = stack_size;
            info.numa_node = numa_node;

            return info;
        }

        fn free(self: *Info) void {
            const stack_ptr = self.getStack().ptr;
            const byte_size = self.stack_size + @sizeOf(Info);
            self.numa_node.free(stack_ptr[0..byte_size]);
        }
    };

    pub const Handle = *Info;

    pub fn spawn(
        numa_node: *Node,
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
                @fence(.Acquire);

                const info = @ptrCast(*Info, @alignCast(@alignOf(*Info), raw_param));
                const param = @intToPtr(Parameter, info.parameter);
                const stack_memory = info.getStack();

                // TODO: https://github.com/ziglang/zig/issues/4699
                // _ = @call(.{ .stack = stack_memory }, entryFn, .{param});
                _ = @asyncCall(stack_memory, {}, asyncEntry, param);
                return 0;
            }
        };

        const info = Info.alloc(numa_node, max_stack_size) orelse return null;
        info.parameter = @ptrToInt(parameter);
        @fence(.Release);
        
        info.handle = windows.kernel32.CreateThread(
            null,
            getAllocationGranularity(),
            Wrapper.entry,
            @ptrCast(windows.PVOID, info),
            windows.STACK_SIZE_PARAM_IS_A_RESERVATION,
            null,
        ) orelse {
            info.free();
            return null;
        };

        @fence(.Release);
        return info;
    }

    pub fn join(handle: Handle) void {
        const info = handle;
        const thread_handle = info.handle;

        windows.WaitForSingleObjectEx(thread_handle, windows.INFINITE, false) catch unreachable;
        windows.CloseHandle(thread_handle);
        info.free();
    }

    var has_allocation_granularity: bool = false;
    var allocation_granularity: usize = undefined;

    fn getAllocationGranularity() usize {
        if (@atomicLoad(bool, &has_allocation_granularity, .Acquire))
            return allocation_granularity;

        var sys_info: windows.SYSTEM_INFO = undefined;
        windows.kernel32.GetSystemInfo(&sys_info);
        const local_alloc_granularity = sys_info.dwAllocationGranularity;

        @atomicStore(
            usize,
            &allocation_granularity,
            local_alloc_granularity,
            .Monotonic,
        );
        @atomicStore(bool, &has_allocation_granularity, true, .Release);
        return local_alloc_granularity;
    }
};