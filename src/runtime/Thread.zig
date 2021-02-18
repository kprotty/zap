const std = @import("std");

pub usingnamespace if (std.builtin.os.tag == .windows)
    WindowsThread
else if (std.builtin.link_libc)
    PosixThread
else if (std.builtin.os.tag == .linux)
    LinuxThread
else
    StdThread;

const StdThread = struct {
    pub fn spawn(comptime entryFn: fn(usize) void, context: usize) bool {
        // we leak since std.Thread doesn't have a good way to do detached threads yet
        _ = std.Thread.spawn(context, entryFn) catch return false;
        return true;
    }
};

const WindowsThread = struct {
    pub fn spawn(comptime entryFn: fn(usize) void, context: usize) bool {
        @compileError("TODO");
    }
};

const PosixThread = struct {
    extern "c" fn pthread_attr_setdetachstate(attr: *std.c.pthread_attr_t, state: c_int) c_int;

    pub fn spawn(comptime entryFn: fn(usize) void, context: usize) bool {
        const Wrapper = struct {
            fn entry(ctx: ?*c_void) callconv(.C) ?*c_void {
                entryFn(@ptrToInt(ctx));
                return null;
            }
        };

        var attr: std.c.pthread_attr_t = undefined;
        if (std.c.pthread_attr_init(&attr) != 0) return false;
        defer std.debug.assert(std.c.pthread_attr_destroy(&attr) == 0);

        if (pthread_attr_setdetachstate(&attr, 1) != 0)
            return false;

        var handle: std.c.pthread_t = undefined;
        const rc = std.c.pthread_create(
            &handle,
            &attr,
            Wrapper.entry,
            @intToPtr(?*c_void, context),
        );

        return rc == 0;
    }
};

const LinuxThread = struct {
    pub fn spawn(comptime entryFn: fn(usize) void, context: usize) bool {
        @compileError("TODO");
    }
};