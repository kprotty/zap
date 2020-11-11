// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const builtin = @import("builtin");

pub const arch_type = builtin.arch;
pub const build_mode = builtin.mode;

pub const is_x86 = switch (arch_type) {
    .i386, .x86_64 => true,
    else => false,
};
pub const is_arm = switch (arch_type) {
    .arm, .aarch64 => true,
    else => false,
};

pub const meta = @import("./meta.zig");
pub const executor = @import("./executor.zig");

pub const sync = struct {
    pub const atomic = @import("./sync/atomic.zig");
};
