const zap = @import("../zap.zig");
const target = zap.target;
const atoimc = zap.sync.atomic;

pub const Event = 
    if (target.is_windows)
        WindowsEvent
    else if (target.has_libc and target.is_posix)
        PosixEvent
    else if (target.is_linux)
        LinuxEvent
    else
        @compileError("OS not supported for thread blocking/unblocking");

const WindowsEvent = struct {
    pub fn wait(self: *Event, callback: anytype) void {

    }

    pub fn notify(self: *Event) void {

    }
};

const LinuxEvent = struct {
    pub fn wait(self: *Event, callback: anytype) void {

    }

    pub fn notify(self: *Event) void {

    }
};

const PosixEvent = struct {
    pub fn wait(self: *Event, callback: anytype) void {

    }

    pub fn notify(self: *Event) void {

    }
};

