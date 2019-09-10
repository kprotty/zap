const std = @import("std");
const builtin = @import("builtin");

pub const backend = switch (builtin.os) {
    .linux => @import("src/backend/linux.zig"),
    .windows => @import("src/backend/windows.zig"),
    .macosx, .freebsd, .netbsd, .openbsd, .dragonfly => @import("src/backend/posix.zig"),
    else => @compileError("Only supports linux, windows and some *BSD variants"),
};

const address = @import("src/address.zig");
const system = @import("src/system.zig");
const socket = @import("src/socket.zig");
const poll = @import("src/poll.zig");

pub usingnamespace address;
pub usingnamespace system;
pub usingnamespace socket;
pub usingnamespace poll;

test "zio" {
    try initialize();
    defer cleanup();
    _ = address;
    _ = socket;
    _ = poll;
}

