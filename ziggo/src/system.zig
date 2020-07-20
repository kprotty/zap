const std = @import("std");

pub usingnamespace
    if (std.builtin.os.tag == .windows)
        struct {
            pub const Node = @import("./windows/node.zig").Node;
            pub const Thread = @import("./windows/thread.zig").Thread;
            pub const nanotime = @import("./windows/time.zig").nanotime;
            pub const AutoResetEvent = @import("./windows/auto_reset_event.zig").AutoResetEvent;
        }
    else if (std.builtin.link_libc)
        struct {
            pub const Node = @import("./posix/node.zig").Node;
            pub const Thread = @import("./posix/thread.zig").Thread;
            pub const AutoResetEvent = @import("./posix/auto_reset_event.zig").AutoResetEvent;
        }
    else if (std.builtin.os.tag == .linux)
        struct {
            pub const Node = @import("./linux/node.zig").Node;
            pub const Thread = @import("./linux/thread.zig").Thread;
            pub const AutoResetEvent = @import("./linux/auto_reset_event.zig").AutoResetEvent;
        }
    else
        @compileError("Operating system not supported");

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
