const std = @import("std");
const builtin = @import("builtin");

const memory = @import("src/mem.zig");
const thread = @import("src/thread.zig");
const allocator = @import("src/allocator.zig");

pub const backend = switch (builtin.os) {
    .linux => @import("src/backend/linux.zig"),
    .windows => @import("src/backend/windows.zig"),
    else => @import("src/backend/posix.zig"),  
};

test "zuma" {
    _ = memory;
    _ = thread;
    _ = allocator;
}

pub usingnamespace thread;
pub const mem = struct {
    pub usingnamespace memory;
    pub usingnamespace allocator;
};