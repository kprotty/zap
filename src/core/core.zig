const std = @import("std");

pub const sync = @import("./sync/sync.zig");

pub const os_type = std.builtin.os.tag;
pub const arch_type = std.builtin.arch;
pub const link_libc = std.builtin.link_libc;
pub const sigle_threaded = std.builtin.single_threaded;

pub const is_linux = os_type == .linux;
pub const is_windows = os_type == .windows;
pub const is_darwin = switch (os_type) {
    .macos, .ios, .watchos, .tvos => true,
    else => false,
};

pub const is_bsd = is_darwin or switch (os_type) {
    .openbsd,
    .freebsd,
    .kfreebsd,
    .netbsd,
    .dragonfly => true,
    else => false,
};

pub const is_posix = link_libc and (
    is_bsd or
    is_linux or
    switch (os_type) {
        .minix,
        .hermit => true,
        else => false,
    }
);

pub const is_x86 = switch (arch_type) {
    .i386, .x86_64 => true,
    else => false,
};

pub const is_arm = switch (arch_type) {
    .arm, .aarch64 => true,
    else => false,
};
