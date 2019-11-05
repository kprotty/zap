const std = @import("std");
const builtin = @import("builtin");

pub const runtime = struct {
    pub usingnamespace @import("src/runtime/executor.zig");

    const system = struct {
        usingnamespace switch (builtin.os) {
            .windows => @import("src/runtime/system/windows.zig"),
            .linux => @import("src/runtime/system/linux.zig"),
            else => @import("src/runtime/system/posix.zig"),
        };
    };
};