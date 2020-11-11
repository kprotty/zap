// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const builtin = @import("builtin");

pub const os_type = builtin.os.tag;
pub const has_libc = builtin.link_libc;

pub const is_linux = os_type == .linux;
pub const is_windows = os_type == .windows;
pub const is_darwin = switch (os_type) {
    .macos, .ios, .watchos, .tvos => true,
    else => false,
};
pub const is_bsd = is_darwin or switch(os_type) {
    .openbsd, .freebsd, .kfreebsd, .netbsd, .dragonfly => true,
    else => false,
};
pub const is_posix = is_linux or is_bsd or switch(os_type) {
    .minix, .haiku => true,
    else => false,
};