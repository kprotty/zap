// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const atomic = @import("../sync/atomic.zig");

pub const Thread = if (std.builtin.os.tag == .windows)
    WindowsThread
else if (std.builtin.link_libc)
    PosixThread
else if (std.builtin.os.tag == .linux)
    LinuxThread
else
    @compileError("Unimplemented Thread primitive for platform");

const WindowsThread = struct {
    handle: std.os.windows.HANDLE,

    const Self = @This();

    pub fn spawn(stack_size: usize, context: anytype, comptime entryFn: anytype) !Self {
        const Context = @TypeOf(context);
        const Wrapper = struct {
            fn entry(raw_arg: std.os.windows.LPVOID) callconv(.C) std.os.windows.DWORD {
                entryFn(@ptrCast(Context, @alignCast(@alignOf(Context), raw_arg)));
                return 0;
            }
        };

        const handle = std.os.windows.kernel32.CreateThread(
            null,
            stack_size,
            Wrapper.entry,
            @ptrCast(std.os.windows.LPVOID, context),
            0,
            null,
        ) orelse return error.SpawnError;

        return Self{ .handle = handle };
    }

    pub fn join(self: Self) void {
        std.os.windows.WaitForSingleObjectEx(self.handle, std.os.windows.INFINITE, false) catch unreachable;
        std.os.windows.CloseHandle(self.handle);
    }
};

const PosixThread = struct {
    handle: std.c.pthread_t,

    const Self = @This();

    pub fn spawn(stack_size: usize, context: anytype, comptime entryFn: anytype) !Self {
        const Context = @TypeOf(context);
        const Wrapper = struct {
            fn entry(raw_arg: ?*c_void) callconv(.C) ?*c_void {
                entryFn(@ptrCast(Context, @alignCast(@alignOf(Context), raw_arg)));
                return null;
            }
        };

        var attr: std.c.pthread_attr_t = undefined;
        if (std.c.pthread_attr_init(&attr) != 0)
            return error.SystemResources;
        defer std.debug.assert(std.c.pthread_attr_destroy(&attr) == 0);
        if (std.c.pthread_attr_setstacksize(&attr, stack_size) != 0)
            return error.SystemResources;

        var handle: std.c.pthread_t = undefined;
        const rc = std.c.pthread_create(
            &handle,
            &attr,
            Wrapper.entry,
            @ptrCast(?*c_void, context),
        );

        return switch (rc) {
            0 => Self{ .handle = handle },
            else => error.SpawnError,
        };
    }

    pub fn join(self: Self) void {
        const rc = std.c.pthread_join(self.handle, null);
        std.debug.assert(rc == 0);
    }
};

const LinuxThread = struct {
    info: *Info,

    const Self = @This();
    const Info = struct {
        mmap_ptr: usize,
        mmap_len: usize,
        context: usize,
        handle: i32,
    };

    pub fn spawn(stack_size: usize, context: anytype, comptime entryFn: anytype) !Self {
        var mmap_size: usize = std.mem.page_size;
        const guard_end = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size + stack_size, std.mem.page_size);
        const stack_end = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size, @alignOf(Info));
        const info_begin = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size + @sizeOf(Info), std.os.linux.tls.tls_image.alloc_align);
        const tls_begin = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size + std.os.linux.tls.tls_image.alloc_size, std.mem.page_size);

        const mmap_bytes = try std.os.mmap(
            null,
            mmap_size,
            std.os.PROT_NONE,
            std.os.MAP_PRIVATE | std.os.MAP_ANONYMOUS,
            -1,
            0,
        );
        errdefer std.os.munmap(mmap_bytes);

        try std.os.mprotect(
            mmap_bytes[guard_end..],
            std.os.PROT_READ | std.os.PROT_WRITE,
        );

        const info = @ptrCast(*Info, @alignCast(@alignOf(Info), &mmap_bytes[info_begin]));
        info.* = .{
            .mmap_ptr = @ptrToInt(mmap_bytes.ptr),
            .mmap_len = mmap_bytes.len,
            .context = @ptrToInt(context),
            .handle = undefined,
        };

        var user_desc: switch (std.builtin.arch) {
            .i386 => std.os.linux.user_desc,
            else => void,
        } = undefined;

        var tls_ptr = std.os.linux.tls.prepareTLS(mmap_bytes[tls_begin..]);
        if (std.builtin.arch == .i386) {
            defer tls_ptr = @ptrToInt(&user_desc);
            user_desc = .{
                .entry_number = std.os.linux.tls.tls_image.gdt_entry_number,
                .base_addr = tls_ptr,
                .limit = 0xfffff,
                .seg_32bit = 1,
                .contents = 0,
                .read_exec_only = 0,
                .limit_in_pages = 1,
                .seg_not_present = 0,
                .useable = 1,
            };
        }

        const flags: u32 =
            std.os.CLONE_SIGHAND | std.os.CLONE_SYSVSEM |
            std.os.CLONE_VM | std.os.CLONE_FS | std.os.CLONE_FILES |
            std.os.CLONE_PARENT_SETTID | std.os.CLONE_CHILD_CLEARTID |
            std.os.CLONE_THREAD | std.os.CLONE_DETACHED | std.os.CLONE_SETTLS;

        const Context = @TypeOf(context);
        const Wrapper = struct {
            fn entry(raw_arg: usize) callconv(.C) u8 {
                const info_ptr = @intToPtr(*Info, raw_arg);
                entryFn(@intToPtr(Context, info_ptr.context));
                return 0;
            }
        };

        const rc = std.os.linux.clone(
            Wrapper.entry,
            @ptrToInt(&mmap_bytes[stack_end]),
            flags,
            @ptrToInt(info),
            &info.handle,
            tls_ptr,
            &info.handle,
        );

        return switch (std.os.linux.getErrno(rc)) {
            0 => Self{ .info = info },
            else => error.SpawnError,
        };
    }

    pub fn join(self: Self) void {
        while (true) {
            const tid = atomic.load(&self.info.handle, .SeqCst);
            if (tid == 0) {
                std.os.munmap(@intToPtr([*]align(std.mem.page_size) u8, self.info.mmap_ptr)[0..self.info.mmap_len]);
                return;
            }

            const rc = std.os.linux.futex_wait(&self.info.handle, std.os.linux.FUTEX_WAIT, tid, null);
            switch (std.os.linux.getErrno(rc)) {
                0 => continue,
                std.os.EINTR => continue,
                std.os.EAGAIN => continue,
                else => unreachable,
            }
        }
    }
};
