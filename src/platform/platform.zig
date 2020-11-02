const std = @import("std");

pub const Futex = @import("./futex.zig").Futex;

pub const os_type = std.builtin.os.tag;
pub const link_libc = std.builtin.link_libc;

pub const is_linux = os_type == .linux;
pub const is_windows = os_type == .windows;
pub const is_darwin = switch (os_type) {
    .macos, .ios, .watchos, .tvos => true,
    else => false,
};

pub const is_android = is_linux and std.builtin.abi == .android;
pub const is_bsd = is_darwin or switch (os_type) {
    .openbsd,
    .freebsd,
    .kfreebsd,
    .netbsd,
    .dragonfly => true,
    else => false,
};

pub const is_posix = is_bsd or is_linux or switch (os_type) {
    .minix,
    .hermit => true,
    else => false,
};

