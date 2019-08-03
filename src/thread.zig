const std = @import("std");
const builtin = @import("builtin");
const memory = @import("memory.zig");

const Backend = switch (builtin.os) {
    .windows => @import("windows/thread.zig"),
    else => @compileError("Platform not supported"),
};

pub const Handle = Backend.Handle;

pub const Error = error {
    Unexpected,
    OutOfMemory,
    TooManyThreads,
};

pub inline fn spawn(comptime function: var, context: var, stack_size: usize) Error!Handle {
    if (builtin.single_threaded)
        @compileError("Cant spawn threads in single-threaded mode");
    comptime std.debug.assert(@ArgType(@typeInfo(function), 0) == @typeOf(context));
    return Backend.spawn(function, context, stack_size);
}

pub inline fn wait(handle: Handle) void {
    return Backend.wait(handle);
}

pub inline fn current() Handle {
    return Backend.current();
}

pub inline fn cpuCount() usize {
    return Backend.cpuCount();
}