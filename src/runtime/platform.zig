const std = @import("std");

pub const is_windows = std.builtin.os.tag == .windows;
pub const is_linux = std.builtin.os.tag == .linux;
pub const is_bsd = switch (std.builtin.os.tag) {
    .macosx, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};
pub const is_posix = std.builtin.link_libc and (is_linux or is_bsd);

const system =  
    if (is_windows)
        struct {
            pub usingnamespace @import("./windows/time.zig");
            pub usingnamespace @import("./windows/numa.zig");
            pub usingnamespace @import("./windows/event.zig");
            pub usingnamespace @import("./windows/thread.zig");
        }
    else if (is_posix)
        struct {
            pub usingnamespace @import("./posix/time.zig");
            pub usingnamespace @import("./posix/numa.zig");
            pub usingnamespace @import("./posix/event.zig");
            pub usingnamespace @import("./posix/thread.zig");
        }
    else if (is_linux)
        struct {

        }
    else @compileError("Operating system not supported");

pub const Event = system.Event;
pub const Thread = system.Thread;
pub const NumaNode = system.NumaNode;

pub const sleep = system.sleep;
pub const nanotime = system.nanotime;

pub const YieldType = enum {
    os,
    cpu,
};

pub fn yield(yield_type: YieldType) void {
    switch (yield_type) {
        .os => system.yield(),
        .cpu => switch (std.builtin.arch) {
            .i386, .x86_64 => asm volatile("pause" ::: "memory"),
            .arm, .aarch64 => asm volatile("yield" ::: "memory"),
            else => {},
        },
    }
}
