const builtin = @import("builtin");
const system = @import("./system.zig");

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
            fn entry(raw_arg: ?system.PVOID) callconv(.C) system.DWORD {
                entryFn(@ptrToInt(raw_arg));
                return 0;
            }
        };
        
        // Create an OS thread and defaults the stack size to the one encoded in the current executable.
        const handle = system.CreateThread(
            null,
            stack_size orelse 0,
            Wrapper.entry,
            @intToPtr(?system.PVOID, parameter),
            @as(system.DWORD, 0),
            null,
        ) orelse return error.SpawnError;

        // Try to set the thread's cpu affinity based on the provided NUMA node number.
        // Given its just a hint, and the thread could exit before this, dont check result.
        if (numa_node) |node| {
            if (node <= @as(usize, ~@as(system.WORD, 0))) {
                var affinity: system.GROUP_AFFINITY = undefined;
                if (system.GetNumaNodeProcessorMaskEx(@intCast(system.WORD, node), &affinity) != 0) {
                    _ = system.SetThreadGroupAffinity(handle, &affinity, null);
                }
            }
        }
        
        // Try to set the ideal processor for the thread.
        // Given its just a hint, and the thread could exit before this, dont check result.
        if (ideal_cpu) |cpu| {
            if ((cpu / 64) <= @as(usize, ~@as(system.WORD, 0))) {
                _ = system.SetThreadIdealProcessorEx(
                    handle,
                    &system.PROCESSOR_NUMBER{
                        .Group = @intCast(system.WORD, cpu / 64),
                        .Number = @intCast(system.BYTE, cpu % 64),
                        .Reserved = 0,
                    },
                    null,
                );
            }
        }

        // Close the handle to detach the thread & prevent resource leaks
        if (system.CloseHandle(handle) == system.FALSE)
            unreachable;
    }
};