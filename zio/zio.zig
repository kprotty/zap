const std = @import("std");
const builtin = @import("builtin");

pub const backend = switch (builtin.os) {
    .linux => @import("src/backend/linux.zig"),
    .windows => @import("src/backend/windows.zig"),
    .macosx, .freebsd, .netbsd, .openbsd, .dragonfly => @import("src/backend/posix.zig"),
    else => @compileError("Only linux, windows and some *BSD variants are supported"),
};

const io = @import("src/io.zig");
const event = @import("src/event.zig");
const socket = @import("src/socket.zig");
const address = @import("src/address.zig");

pub usingnamespace io;
pub usingnamespace event;
pub usingnamespace socket;
pub usingnamespace address;

test "zio" {
    //_ = io;
    //_ = event;
    //_ = socket;
    //_ = address;
}