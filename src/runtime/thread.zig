const std = @import("std");
const builtin = @import("builtin");

const Backend = switch (builtin.os) {
    .windows => Kernel32,
    .linux => if (builtin.link_libc) Pthread else LinuxClone,
    else => Pthread,
};

/// Clock get current time in milliseconds
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

pub fn yieldCpu() void {
    switch (builtin.arch) {
        .i386, .x86_64 => asm volatile("pause" ::: "memory"),
        .arm, .aarch64 => asm volatile("yield"),
        else => {},
    }
}

const Kernel32 = struct {
    const windows = std.os.windows;
    var module: ?windows.HANDLE = null;
    var frequency: u64 = 0;

    extern "kernel32" stdcallcc fn SwitchToThread() windows.BOOL;
    extern "kernel32" stdcallcc fn GetModuleHandleA(lpModuleName: ?[*]u8) windows.HANDLE;
    extern "kernel32" stdcallcc fn GetProcessAffinityMask(
        hProcess: windows.HANDLE,
        lpProcessAffinityMask: *windows.DWORD,
        lpSystemAffinityMask: *windows.DWORD,
    ) windows.BOOL;

    pub fn yield() void {
        _ = SwitchToThread();
    }

    pub fn sleep(ms: u32) void {
        windows.kernel32.Sleep(ms);
    }

    pub fn now() u64 {
        if (@atomicLoad(u64, &frequency, .Acquire) == 0) {
            var frequency_counter: u64 = undefined;
            if (windows.QueryPerformanceFrequency(&frequency_counter) != windows.TRUE)
                _ = @atomicRmw(u64, &frequency, .Xchg, frequency_counter, .Release);
        }

        std.debug.assert(frequency > 0);
        var performance_count: u64 = undefined;
        std.debug.assert(windows.QueryPerformanceCounter(&performance_count) == windows.TRUE);
        return ((performance_count * 1000000) / frequency) / 1000;
    }

    pub fn cpuCount() usize {
        var system_mask: windows.DWORD = undefined;
        var process_mask: windows.DWORD = undefined;
        
        if (@atomicLoad(?windows.HANDLE, &module, .Acquire) == null)
            _ = @atomicRmw(?windows.HANDLE, &module, .Xchg, GetModuleHandleA(null), .Release);
        if (GetProcessAffinityMask(module.?, &process_mask, &system_mask) != windows.TRUE)
            return 1;
        if (process_mask != 0)
            return usize(@popCount(windows.DWORD, process_mask));
        
        var system_info: windows.SYSTEM_INFO = undefined;
        windows.kernel32.GetSystemInfo(&system_info);
        return @intCast(usize, system_info.dwNumberOfProcessors);
    }

    pub fn stackSize(comptime function: var) usize {
        return 0; // windows doesnt allow custom thread stacks
    }

    pub fn spawn(stack: ?[]align(std.mem.page_size) u8, comptime function: var, parameter: var) !void {
        const Thread = struct {
            extern fn main(argument: windows.LPVOID) windows.DWORD {
                const Parameter = @typeOf(parameter);
                _ = function(@ptrCast(Parameter, @alignCast(@alignOf(Parameter), argument)));
                return 0;
            }
        };

        const handle = windows.kernel32.CreateThread(null, 64 * 1024, Thread.main, @ptrCast(*c_void, parameter), 0, null)
            orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        _ = windows.CloseHandle(handle);
    }
};

const LinuxClone = struct {
    const linux = std.os.linux;

    pub fn yield() void {
        _ = linux.syscall0(linux.SYS_sched_yield);
    }

    pub fn sleep(ms: u32) void {
        return Pthread.sleep(ms);
    }
    
    pub fn now() u64 {
        var ts: linux.timespec = undefined;
        std.debug.assert(linux.clock_gettime(linux.CLOCK_MONOTONIC, &ts) == 0);
        return @intCast(u64, (ts.tv_sec * 1000) + (ts.tv_nsec / 1000000));
    }

    pub fn cpuCount() usize {
        return usize(std.os.CPU_COUNT(std.os.sched_getaffinity(0) catch return 1));
    }

    pub fn stackSize(comptime function: var) usize {
        var stack_size = Pthread.setupStackSize(function, i32);
        if (linux.tls.tls_image) |tls_image|
            stack_size = std.mem.alignForward(stack_size, @alignOf(usize)) + tls_image.alloc_size;
        return std.mem.alignForward(stack_size, std.mem.page_size);
    }

    pub fn spawn(stack: ?[]align(std.mem.page_size) u8, comptime function: var, parameter: var) !void {
        const Thread = struct {
            extern fn main(argument: usize) u8 {
                _ = function(@intToPtr(@typeOf(parameter), argument));
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
        if (linux.tls.tls_image) |tls_image| {
            flags |= std.os.CLONE_TLS;
            const tls_start = memory.len - tls_image.alloc_size;
            tls_offset = linux.tls.copyTLS(@ptrToInt(&memory[tls_start]));
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

    pub fn yield() void {
        _ = std.c.pthread_yield();
    }

    pub fn sleep(ms: u32) void {
        std.os.nanosleep(ms / 1000, (ms % 1000) * 1000000);
    }

    pub fn now() u64 {
        var tv: std.os.system.timeval = undefined;
        std.debug.assert(std.c.gettimeofday(&tv, null) == 0);
        return @intCast(usize, (tv.tv_sec / 1000) + (tv.tv_usec * 1000));
    }

    pub fn cpuCount() usize {
        var count: c_int = undefined;
        var length: usize = @sizeOf(@typeOf(count));
        const name = if (std.os.darwin.is_the_target) c"hw.logicalcpu" else c"hw.ncpu";
        std.os.sysctlbynameC(name, &count, &length, null, 0) catch |err| switch (err) {
            .NameTooLong => unreachable,
            else => return 1,
        };
        return @intCast(usize, count);
    }

    pub fn stackSize(comptime function: var) usize {
        return setupStackSize(function, std.c.pthread_t);
    }

    pub fn spawn(stack: ?[]align(std.mem.page_size) u8, comptime function: var, parameter: var) !void {
        const Thread = struct {
            extern fn main(argument: ?*c_void) ?*c_void {
                const Parameter = @typeOf(parameter);
                _ = function(@ptrCast(Parameter, @alignCast(@alignOf(Parameter), argument)));
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
        try std.os.protect(memory[0..guard_page_size], os.PROT_NONE);
    }
};