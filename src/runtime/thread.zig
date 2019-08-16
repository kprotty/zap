const std = @import("std");
const builtin = @import("builtin");

const Backend = switch (builtin.os) {
    .windows => Kernel32,
    .linux => if (builtin.link_libc) Pthread else LinuxClone,
    else => Pthread,
};

/// Clock get current time
pub const now = Backend.now;
/// Yield the OS thread
pub const yield = Backend.yield;
/// Sleep for `usize` milliseconds
pub const sleep = Backend.sleep;
/// Get the number of configured cpu cores
pub const cpuCount = Backend.cpuCount;
/// Given a comptime function, get the required thread stack size
pub const stackSize = Backend.stackSize;
/// Spawn a thread using a function and parameter with stack memory >= `stackSize()`
pub const spawn = Backend.spawn;


const Kernel32 = struct {

};

const LinuxClone = struct {
    pub fn now() usize {
        
    }

    pub fn yield() void {

    }

    pub fn cpuCount() usize {
        
    }

    pub fn sleep(ms: u32) void {

    }

    pub fn stackSize(comptime function: var) usize {
        var stack_size = Pthread.setupStackSize(function, i32);
        if (std.os.linux.tls.tls_image) |tls_image|
            stack_size = std.mem.alignForward(stack_size, @alignOf(usize)) + tls_image.alloc_size;
        return std.mem.alignForward(stack_size, std.mem.page_size);
    }

    pub fn spawn(stack: ?[]align(std.mem.page_size) u8, comptime function: var, parameter: var) !void {
        const Thread = struct {
            extern fn main(argument: usize) u8 {
                _ = async function(@intToPtr(@typeOf(parameter), argument));
                return 0;
            }
        };

        var tid: *i32 = undefined;
        var tls_offset: usize = undefined;
        var stack_offset: usize = undefined;
        var flags: u32 = std.os.CLONE_VM | std.os.CLONE_FS | std.os.CLONE_FILES |
            std.os.CLONE_THREAD | std.os.CLONE_SYSVSEM | std.os.CLONE_DETATCHED |
            std.os.CLONE_PARENT_SETTID | std.os.CLONE_CHILD_CLEARTID | std.os.CLONE_SIGHAND;

        const memory = stack orelse return error.StackRequired;
        try Pthread.setupStack(memory, function, &tid, &stack_offset);
        if (std.os.linux.tls.tls_image) |tls_image| {
            flags |= std.os.CLONE_TLS;
            const tls_start = memory.len - tls_image.alloc_size;
            tls_offset = std.os.linux.tls.copyTLS(@ptrToInt(&memory[tls_start));
        }

        return switch (os.errno(os.linux.clone(Thread.main, stack_offset, flags, @ptrToInt(parameter), tid, tls_offset, tid))) {
            0 => {},
            std.os.EAGAIN => error.TooManyThreads,
            std.os.ENOMEM => error.OutOfThreadMemory,
            std.os.EINVAL, std.os.ENOSPC, std.os.EPERM, std.os.EUSERS => unreachable,
            else => |err| return std.os.unexpectedError(err),
        };
    }
};

const Pthread = struct {
    const guard_page_size = std.mem.page_size;

    pub fn now() usize {
        
    }

    pub fn yield() void {

    }

    pub fn cpuCount() usize {
        
    }

    pub fn sleep(ms: u32) void {

    }

    pub fn stackSize(comptime function: var) usize {
        return setupStackSize(function, std.c.pthread_t);
    }

    pub fn spawn(stack: ?[]align(std.mem.page_size) u8, comptime function: var, parameter: var) !void {
        const Thread = struct {
            extern fn main(argument: ?*c_void) ?*c_void {
                const Parameter = @typeOf(parameter);
                _ = async function(@ptrCast(Parameter, @alignCast(@alignOf(Parameter), argument)));
                return null;
            }
        };

        var attr: std.c.pthread_attr_t = undefined;
        if (std.c.pthread_attr_init(&attr) != 0)
            return error.OutOfThreadMemory;
        defer std.debug.assert(std.c.pthread_attr_destroy(&attr) == 0);

        const memory = stack orelse return error.StackRequired;
        var tid: *c.pthread_t = undefined;
        var stack_offset: usize = undefined;
        try setupStack(memory, function, &tid, &stack_offset);
        std.debug.assert(std.c.pthread_attr_setstack(&attr, memory.ptr, stack_offset) == 0);
        
        const err = std.c.pthread_create(tid, &attr, Thread.main, @ptrCast(?*c_void, parameter));
        return switch (err) {
            0 => return {},
            std.os.EPERM, std.os.EINVAL => unreachable,
            std.os.EAGAIN => return error.OutOfThreadMemory,
            else => return std.os.unexpectedError(@intCast(usize, err)),
        };
    }

    pub fn setupStackSize(comptime function: var, comptime thread_id: type) usize {
        var stack_size = std.mem.alignForward(@frameSize(function) + guard_page_size, std.mem.page_size);
        stack_size = std.mem.alignForward(stack_size, @alignOf(thread_id)) + @sizeOf(thread_id);
        return std.mem.alignForward(stack_size, std.mem.page_size);
    }

    pub fn setupStack(memory: []align(std.mem.page_size) u8, comptime function: var, tid: var, stack_offset: *usize) !void {
        const thread_id = @typeInfo(@typeInfo(@typeOf(tid)).Pointer.child).Pointer.child;
        stack_offset.* = std.mem.alignForward(guard_page_size + @frameSize(function), std.mem.page_size);
        tid.* = @intToPtr(*thread_id, std.mem.alignForward(stack_offset.*, @alignOf(thread_id)));
        try std.os.protect(memory[guard_page_size..], os.PROT_READ | os.PROT_WRITE);
    }
};