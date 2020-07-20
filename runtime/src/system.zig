const std = @import("std");

pub fn spinLoopHint(iterations: usize) void {
    var i = iterations;
    while (i != 0) : (i -= 1) {
        switch (std.builtin.arch) {
            .i386, .x86_64 => asm volatile("pause" ::: "memory"),
            .arm, .aarch64 => asm volatile("yield" ::: "memory"),
            else => {},
        }
    }
}

pub usingnamespace
    if (std.builtin.os.tag == .windows)
        struct {
            pub usingnamespace @import("./windows/time.zig");
            pub usingnamespace @import("./windows/node.zig");
            pub usingnamespace @import("./windows/thread.zig");
            pub usingnamespace @import("./windows/signal.zig");
        }
    else if (std.builtin.link_libc)
        struct {

        }
    else if (std.builtin.os.tag == .linux)
        struct {

        }
    else
        @compileError("Platform not supported");