const std = @import("std");
const builtin = @import("builtin");

pub const backend = switch (builtin.os) {
    .linux => @import("src/backend/linux.zig"),
    .windows => @import("src/backend/windows.zig"),
    .macosx, .freebsd, .netbsd, .openbsd, .dragonfly => @import("src/backend/posix.zig"),
    else => @compileError("Only supports linux, windows and some *BSD variants"),
};

test "zio" {
    
}