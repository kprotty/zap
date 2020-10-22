// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");

pub fn spinLoopHint() void {
    switch (std.builtin.arch) {
        .i386, .x86_64 => asm volatile("pause" ::: "memory"),
        .arm, .aarch64 => asm volatile("yield" ::: "memory"),
        else => {},
    }
}

pub const Waker = struct {
    wakeFn: fn(*Waker) void,

    pub fn wake(self: *Waker) void {
        return (self.wakeFn)(self);
    }
};

pub const SuspendContext = struct {
    suspendFn: fn(*SuspendContext) bool,

    pub fn @"suspend?"(self: *SuspendContext) bool {
        return (self.suspendFn)(self);
    }
};

pub const Lock = @import("./lock.zig").Lock; 