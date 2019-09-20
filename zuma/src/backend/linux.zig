const std = @import("std");
const builtin = @import("builtin");
const zuma = @import("../../zuma.zig");

const os = std.os;
const linux = os.linux;

fn toTimespec(ms: u32) linux.timespec {
    return linux.timespec {
        .tv_sec = @intCast(isize, ms / 1000),
        .tv_nsec = @intCast(isize, (ms % 1000) * 1000000),
    };
}

pub const Thread = if (builtin.link_libc) @import("posix.zig").Thread else struct {
    id: *i32,

    pub fn now(is_monotonic: bool) u64 {
        var ts: linux.timespec = undefined;
        const clock_type = if (is_monotonic) linux.CLOCK_MONOTONIC else linux.CLOCK_REALTIME;
        return switch (os.errno(linux.clock_gettime(clock_type, &ts))) {
            0 => (@intCast(u64, ts.tv_sec) * 1000) + (@intCast(u64, ts.tv_nsec) / 1000000),
            os.EFAULT, os.EPERM => unreachable,
            else => unreachable,
        };
    }

    pub fn sleep(ms: u32) void {
        var ts = toTimespec(ms);
        while (true) {
            switch (os.errno(linux.nanosleep(&ts, &ts))) {
                0, os.EINVAL => return,
                os.EINTR => continue,
                else => unreachable,
            }
        }
    }

    pub fn yield() void {
        _ = linux.syscall0(linux.SYS_sched_yield);
    }

    pub fn getStackSize(comptime function: var) usize {
        var size = @sizeOf(i32) + @frameSize(function);
        size = std.mem.alignForward(size, zuma.mem.page_size);
        if (linux.tls.tls_image) |tls_image|
            size = std.mem.alignForward(size, @alignOf(usize)) + tls_image.alloc_size;
        return size;
    }

    pub fn spawn(stack: ?[]align(zuma.mem.page_size) u8, comptime function: var, parameter: var) zuma.Thread.SpawnError!@This() {
        const memory = stack orelse return zuma.Thread.SpawnError.InvalidStack;
        var id = @ptrCast(*i32, memory[0])
        var clone_flags = 
            os.CLONE_VM | os.CLONE_FS | os.CLONE_FILES |
            os.CLONE_CHILD_CLEARTID | os.CLONE_PARENT_SETTID |
            os.CLONE_THREAD | os.CLONE_SIGHAND | os.CLONE_SYSVSEM;

        var tls_offset: usize = undefined;
        if (system.tls.tls_image) |tls_image| {
            clone_flags |= os.CLONE_SETTLS;
            tls_offset = memory.len - tls_image.alloc_size;
            tls_offset = system.tls.copyTLS(@ptrToInt(&memory[tls_offset]));
        }

        const Wrapper = struct {
            extern fn entry(arg: usize) u8 {
                _ = function(zuma.mem.transmute(@typeOf(parameter), arg));
                return 0;
            }
        };
        
        var stack_offset = @sizeOf(@typeOf(id)) + @frameSize(function);
        stack_offset = std.mem.alignForward(stack_offset, zuma.mem.page_size);
        const stack_ptr = @ptrToInt(&memory[stack_offset]);
        const arg = std.mem.transmute(usize, parameter);
        return switch (os.errno(system.clone(Wrapper.entry, stack_ptr, clone_flags, arg, id, tls_offset, id))) {
            0 => @This() { .id = id },
            os.EPERM, os.EINVAL, os.ENOSPC, os.EUSERS => unreachable,
            os.EAGAIN => zuma.Thread.SpawnError.TooManyThreads,
            os.ENOMEM => zuma.Thread.SpawnError.OutOfMemory,
            else => unreachable,
        };
    }

    pub fn join(self: *@This(), timeout_ms: ?u32) void {
        var ts: linux.timespec = if (timeout_ms) |t| toTimespec(t) else undefined;
        const timeout = if (timeout_ms) |_| &ts else null;
        return switch (os.errno(linux.futex_wait(self.id, linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG, self.id.*, timeout))) {
            0, os.EINTR, os.EAGAIN => {},
            os.EINVAL => unreachable,
            else => unreachable,
        };
    }

    pub fn setCurrentAffinity(cpu_set: *const CpuSet) !void {
        // TODO
    }

    pub fn getCurrentAffinity(cpu_set: *CpuSet) !void {
        // TODO
    }
};