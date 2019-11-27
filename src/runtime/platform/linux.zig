const std = @import("std");
const linux = std.os.linux;
const posix = @import("./posix.zig");

pub fn nanotime = posix.nanotime;

pub const Thread = if (builtin.link_libc) posix.Thread else struct {
    tid: i32,

    pub fn getCurrent(self: *Thread) void {
        _ = linux.syscall1(linux.SYS_set_tid_address, @ptrToInt(&self.tid));
    }

    pub fn join(self: *Thread) void {
        while (true) {
            const tid = @atomicLoad(i32, &self.tid, .Acquire);
            if (tid == 0) return;
            const rc = linux.futex_wait(&self.tid, linux.FUTEX_WAIT, tid, null);
            switch (linux.getErrno(rc)) {
                0 => continue,
                os.EINTR => continue,
                os.EAGAIN => continue,
                else => unreachable,
            }
        }
    }

    pub fn spawn(parameter: var, comptime entryFn: var) std.Thread.SpawnError!void {
        const DEFAULT_STACK_SIZE = 2 * 1024 * 1024;
        const Parameter = @typeOf(parameter);
        const Wrapper = struct {
            extern fn entry(arg: usize) u8 {
                _ = entryFn(@intToPtr(Parameter, arg));
                return 0;
            }
        };

        // compute the stack size & offsets
        var stack_size: usize = std.mem.page_size;
        const guard_offset = stack_size;
        var tls_offset: usize = undefined;
        if (linux.tls.tls_image) |tls_image| {
            stack_size = std.mem.alignForward(stack_size, @alignOf(usize));
            tls_offset = stack_size;
            stack_size += tls_image.alloc_size;
        }

        // only alloc in sizes multiple of DEFAULT_STACK_SIZE to avoid VMA space fragmentation
        const old_stack_size = stack_size;
        stack_size = std.mem.alignForward(stack_size, DEFAULT_STACK_SIZE);
        if (stack_size - old_stack_size < DEFAULT_STACK_SIZE / 2)
            stack_size += DEFAULT_STACK_SIZE;

        // allocate the stack space
        const stack = std.os.mmap(null, stack_size, linux.PROT_NONE, linux.MAP_PRIVATE | linux.MAP_ANONYMOUS, -1, 0) catch |err| switch (err) {
            std.os.MMapError.MemoryMappingNotSupported => unreachable,
            std.os.MMapError.PermissionDenied => unreachable,
            std.os.MMapError.AccessDenied => unreachable,
            else => |e| return e,
        };
        errdefer std.os.munmap(stack);

        // make all except the guard page usable
        std.os.mprotect(stack[guard_offset..], linux.PROT_READ | linux.PROT_WRITE) catch |err| switch (err) {
            std.os.MProtectError.AccessDenied => unreachable,
            else => |e| return e,
        }

        // spawn the thread
        var tid: i32 = undefined;
        const arg = @ptrToInt(parameter);
        var flags: u32 = linux.CLONE_VM | linux.CLONE_FS | linux.CLONE_SYSVSEM
            | linux.CLONE_THREAD | linux.CLONE_DETACHED | linux.SIGHAND
            | linux.CLONE_CHILD_CLEARTID | linux.CLONE_PARENT_SETTID;
        if (linux.tls.tls_image) |tls_image| {
            tls_offset = linux.tls.copyTLS(@ptrToInt(&stack[tls_offset]));
            flags |= linux.CLONE_SETTLS;
        }
        const rc = linux.clone(Wrapper.entry, @ptrToInt(stack.ptr) + stack.len, flags, arg, &tid, tls_offset, &tid);
        switch (linux.getErrno(rc)) {
            linux.EAGAIN => return std.Thread.SpawnError.ThreadQuotaExceeded,
            linux.ENOMEM => return std.Thread.SpawnError.SystemResources,
            linux.EINVAL => unreachable,
            linux.ENOSPC => unreachable,
            linux.EUSERS => unreachable,
            linux.EPERM => unreachable,
            else => unreachable,
        }
    }
};
