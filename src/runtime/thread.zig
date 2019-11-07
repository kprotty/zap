const std = @import("std");
const builtin = @import("builtin");

pub const Thread = switch (builtin.os) {
    .linux => if (builtin.link_libc) PosixThread else LinuxThread,
    .windows => WindowsThread,
    else => PosixThread,
};

const WindowsThread = struct {

};

const LinuxThread = struct {
    const linux = std.os.linux;

    pub fn yield() void {
        const rc = linux.syscall0(linux.SYS_sched_yield);
        std.debug.assert(rc == 0);
    } 
};

const PosixThread = struct {

};