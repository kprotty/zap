const std = @import("std");

pub const Thread = if (std.builtin.os.tag == .windows)
    WindowsThread
else if (std.builtin.link_libc)
    PosixThread
else if (std.builtin.os.tag == .linux)
    LinuxThread
else
    @compileError("Platform not supported");

const WindowsThread = struct {
    pub fn spawn(comptime entryFn: fn(@This(), usize) void, context: usize) bool {
        const Wrapper = struct {
            fn entry(raw_arg: std.os.windows.LPVOID) callconv(.C) std.os.windows.DWORD {
                entryFn(@ptrToInt(raw_arg));
                return 0;
            }
        };
        
        const handle = std.os.windows.kernel32.CreateThread(
            null,
            0, // use default stack size
            Wrapper.entry,
            @intToPtr(std.os.windows.LPVOID, &spawner),
            0,
            null,
        ) orelse return false;

        // closing the handle detaches the thread
        std.os.windows.CloseHandle(handle);
        return true;
    }
};

const PosixThread = struct {
    pub fn spawn(comptime entryFn: fn(usize) void, context: usize) bool {
        const Wrapper = struct {
            fn entry(ctx: ?*c_void) callconv(.C) ?*c_void {
                entryFn(@ptrToInt(ctx));
                return null;
            }
        };

        var handle: std.c.pthread_t = undefined;
        const rc = std.c.pthread_create(
            &handle,
            null,
            Wrapper.entry,
            @intToPtr(?*c_void, context),
        );

        return rc == 0;
    }
};

const LinuxThread = struct {
    pub fn spawn(comptime entryFn: fn(@This(), usize) void, context: usize) bool {
        @compileError("TODO");
    }

    pub fn join(self: @This()) void {
        @compileError("TODO");
    }
};