const builtin = @import("builtin");

pub const Thread = switch (builtin.os.tag) {
    .linux => LinuxThread,
    .windows => WindowsThread,
    .netbsd => NetBSDThread,
    .openbsd => OpenBSDThread,
    .dragonfly => DragonflyThread,
    .freebsd, .kfreebsd => FreeBSDThread,
    .macos, .ios, .watchos, .tvos => DarwinThread,
    else => @compileError("OS not supported for thread blocking/unblocking"),
};

// clone()
const LinuxThread = @compileError("TODO");

// lwp_create()
const NetBSDThread = @compileError("TODO");

// tfork
const OpenBSDThread = @compileError("TODO");

// thr_new
const FreeBSDThread = @compileError("TODO");

// lwp_create
const DragonflyThread = @compileError("TODO");

// pthread_create
const DarwinThread = @compileError("TODO");

// CreateThread
const WindowsThread = struct {
    pub fn spawn(
        numa_node: ?usize,
        ideal_cpu: ?usize,
        stack_size: ?usize,
        parameter: usize,
        comptime entryFn: fn(usize) void,
    ) !void {
        const Wrapper = struct {
            fn entry(raw_arg: ?*c_void) callconv(.C) u32 {
                entryFn(@ptrToInt(raw_arg));
                return 0;
            }
        };
        
        // Create an OS thread and defaults the stack size to the one encoded in the current executable.
        const handle = CreateThread(
            null,
            stack_size orelse 0,
            Wrapper.entry,
            @intToPtr(?*c_void, parameter),
            @as(u32, 0),
            null,
        ) orelse return error.SpawnError;

        // Try to set the thread's cpu affinity based on the provided NUMA node number.
        // Given its just a hint, and the thread could exit before this, dont check result.
        if (numa_node) |node| {
            if (node <= @as(usize, ~@as(u16, 0))) {
                var affinity: GROUP_AFFINITY = undefined;
                if (GetNumaNodeProcessorMaskEx(@intCast(u16, node), &affinity) != 0) {
                    _ = SetThreadGroupAffinity(handle, &affinity, null);
                }
            }
        }
        
        // Try to set the ideal processor for the thread.
        // Given its just a hint, and the thread could exit before this, dont check result.
        if (ideal_cpu) |cpu| {
            if ((cpu / 64) <= @as(usize, ~@as(u16, 0))) {
                _ = SetThreadIdealProcessorEx(
                    handle,
                    &PROCESSOR_NUMBER{
                        .Group = @intCast(u16, cpu / 64),
                        .Number = @intCast(u8, cpu % 64),
                        .Reserved = 0,
                    },
                    null,
                );
            }
        }

        // Close the handle to detach the thread & prevent resource leaks
        if (CloseHandle(handle) == 0)
            unreachable;
    }
    
    const WINAPI = if (builtin.arch == .i386) .Stdcall else .C;
    const PROCESSOR_NUMBER = extern struct {
        Group: u16,
        Number: u8,
        Reserved: u8,
    };
    const GROUP_AFFINITY = extern struct {
        Mask: usize,
        Group: u16,
        Reserved: [3]u16,
    };

    extern "kernel32" fn CloseHandle(
        handle: ?*c_void,
    ) callconv(WINAPI) c_int;
    extern "kernel32" fn CreateThread(
        lpThreadAttributes: ?*c_void,
        dwStackSize: usize,
        lpStartAddress: fn(?*c_void) callconv(.C) u32,
        lpParameter: ?*c_void,
        dwCreationFlags: u32,
        dwThreadId: ?*u32,
    ) callconv(WINAPI) ?*c_void;
    extern "kernel32" fn GetNumaNodeProcessorMaskEx(
        nNode: u16,
        pProcessorMask: ?*GROUP_AFFINITY,
    ) callconv(WINAPI) c_int;
    extern "kernel32" fn SetThreadIdealProcessorEx(
        hThread: ?*c_void,
        lpIdealProcessor: ?*const PROCESSOR_NUMBER,
        lpPrevIdealProcessor: ?*PROCESSOR_NUMBER,
    ) callconv(WINAPI) c_int;
    extern "kernel32" fn SetThreadGroupAffinity(
        hThread: ?*c_void,
        lpGroupAffinity: ?*const GROUP_AFFINITY,
        lpPrevGroupAffinity: ?*GROUP_AFFINITY,
    ) callconv(WINAPI) c_int;
};