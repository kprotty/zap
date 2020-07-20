const std = @import("std");
const linux = std.os.linux;
const Node = @import("./node.zig").Node;

pub const Thread = struct {
    pub const Affinity = struct {
        begin: u16,
        end: u16,

        pub fn getCount(self: Affinity) usize {
            return (self.end + 1) - self.begin;
        }

        pub fn bindCurrentThread(self: Affinity) void {
            var cpu_set: [1 << @typeInfo(u16).Int.bits]u8 align(@alignOf(c_long)) = undefined;
            cpu_set = std.mem.zeroes(@TypeOf(cpu_set));

            var cpu = self.begin;
            std.debug.assert(self.begin <= self.end);
            while (cpu <= self.end) : (cpu += 1) {
                cpu_set[cpu / 8] |= @as(u8, 1) << @intCast(std.math.Log2Int(u8), cpu % 8);
            }

            const pid = 0;
            _ = linux.syscall3(
                .sched_setaffinity,
                pid,
                cpu_set.len,
                @ptrToInt(&cpu_set[0]),
            );
        }
    };

    const Tasklet = extern struct {
        stack_ptr: usize,
        stack_len: usize,
        parameter: usize,
        node: *Node,
    };

    pub const Handle = *Tasklet;

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
            fn entry(raw_param: usize) callconv(.C) u8 {
                const tasklet = @intToPtr(*Tasklet, raw_param);
                const param = @intToPtr(Parameter, tasklet.parameter);
                thread_handle = tasklet;
                _ = @call(.{}, entryFn, .{param});
                return 0;
            }
        };

        var bytes: usize = 0;
        var stack_size = std.mem.alignForward(max_stack_size, std.mem.page_size);
        stack_size = std.math.max(stack_size, 16 * 1024);
        bytes += stack_size;
        const stack_end_offset = bytes;

        bytes = std.mem.alignForward(bytes, @alignOf(Tasklet));
        const tasklet_offset = bytes;
        bytes += @sizeOf(Tasklet);

        bytes = std.mem.alignForward(bytes, linux.tls.tls_image.alloc_align);
        const tls_offset = bytes;
        bytes += linux.tls.tls_image.alloc_size;
        
        const memory = node.alloc(std.mem.page_size, bytes) orelse return null;
        const tasklet = @ptrCast(*Tasklet, @alignCast(@alignOf(*Tasklet), &memory[tasklet_offset]));
        tasklet.* = Tasklet{
            .stack_ptr = @ptrToInt(memory.ptr),
            .stack_len = memory.len,
            .parameter = @ptrToInt(parameter),
            .node = node,
        };

        const tls_value = linux.tls.prepareTLS(memory[tls_offset..]);
        var user_desc: if (std.builtin.arch == .i386) linux.user_desc else void = undefined;
        const tls_ptr = blk: {
            if (std.builtin.arch == .i386) {
                user_desc = linux.user_desc{
                    .entry_number = linux.tls.tls_image.gdt_entry_number,
                    .base_addr = tls_value,
                    .limit = 0xfffff,
                    .seg_32bit = 1,
                    .contents = 0, // Data
                    .read_exec_only = 0,
                    .limit_in_pages = 1,
                    .seg_not_present = 0,
                    .useable = 1,
                };
                break :blk @ptrToInt(&user_desc);
            } else {
                break :blk tls_value;
            }
        };

        const flags: u32 = 
            linux.CLONE_VM | linux.CLONE_THREAD |
            linux.CLONE_FS | linux.CLONE_FILES |
            linux.CLONE_SIGHAND | linux.CLONE_SYSVSEM |
            linux.CLONE_DETACHED | linux.CLONE_SETTLS;

        var handle: i32 = undefined;
        const ret = linux.clone(
            Wrapper.entry,
            @ptrToInt(memory.ptr) + stack_end_offset,
            flags,
            @ptrToInt(tasklet),
            &handle,
            tls_ptr,
            &handle,
        );

        switch (linux.getErrno(ret)) {
            0 => return tasklet,
            linux.EAGAIN => {},
            linux.ENOMEM => {},
            linux.EINVAL => unreachable,
            linux.ENOSPC => unreachable,
            linux.EPERM => unreachable,
            linux.EUSERS => unreachable,
            else => |err| {
                _ = std.os.unexpectedErrno(err) catch {};
            },
        }

        node.free(std.mem.page_size, memory);
        return null;
    }

    pub fn join(handle: Handle) void {
        const tasklet = handle;
        const memory_len = tasklet.stack_len;
        const memory_ptr = @intToPtr([*]align(std.mem.page_size) u8, tasklet.stack_ptr);
        tasklet.node.free(std.mem.page_size, memory_ptr[0..memory_len]);
    }
};

