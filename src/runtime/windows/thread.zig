const std = @import("std");
const system = std.os.system;

pub const Thread = struct {
    pub const Handle = system.HANDLE;

    pub fn spawn(
        comptime entryFn: fn(Handle, usize) void,
        parameter: usize,
        stack_size: u32,
    ) !Handle {
        
    }

    pub fn join(handle: Handle) void {

    }
};