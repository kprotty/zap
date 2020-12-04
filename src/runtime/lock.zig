const zap = @import("../zap.zig");
const target = zap.target;

pub const Lock = 
    if (target.is_windows)
        WindowsLock
    else if (target.is_posix)
        PosixLock
    else
        @compileError("OS not supported for blocking locks");

const WindowsLock = struct {

    pub fn acquire(self: *Lock) void {

    }

    pub fn release(self: *Lock) void {

    }
};

const PosixLock = struct {

    pub fn acquire(self: *Lock) void {

    }

    pub fn release(self: *Lock) void {
        
    }
};