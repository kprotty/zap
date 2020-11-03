const std = @import("std");

pub const sync = @import("./sync/sync.zig");
pub const executor = @import("./executor.zig");

pub const arch_type = std.builtin.arch;
pub const sigle_threaded = std.builtin.single_threaded;

pub const is_x86 = switch (arch_type) {
    .i386, .x86_64 => true,
    else => false,
};

pub const is_arm = switch (arch_type) {
    .arm, .aarch64 => true,
    else => false,
};
