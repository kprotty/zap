const std = @import("std");

// pub const Thread = if (std.builtin.os.tag == .windows)
//     WindowsThread
// else if (std.builtin.link_libc)
//     PosixThread
// else if (std.builtin.os.tag == .linux)
//     LinuxThread
// else
//     @compileError("Platform not supported");

pub const Thread = struct {
    pub fn spawn(comptime entryFn: fn(usize) void, context: usize) bool {
        const t = std.Thread.spawn(.{}, entryFn, .{context}) catch return false;
        t.detach();
        return true;
    }
};
