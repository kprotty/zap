// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const zap = @import("../zap.zig");

pub fn yieldCpu(iterations: usize) void {
    std.SpinLock.loopHint(iterations);
}

pub const core = struct {
    pub const Lock = @import("./lock.zig").Lock;
};

pub const task = struct {
    pub const AutoResetEvent = zap.Task.AutoResetEvent;

    pub const Lock = core.Lock(AutoResetEvent);
};

pub const os = struct {
    pub const AutoResetEvent = struct {
        inner: std.AutoResetEvent = std.AutoResetEvent{},

        pub fn set(self: *AutoResetEvent) void {
            self.inner.set();
        }

        pub fn wait(self: *AutoResetEvent) void {
            self.inner.wait();
        }
        
        pub fn yield() void {
            std.os.sched_yield() catch unreachable;
        }
    };

    pub const Lock = core.Lock(AutoResetEvent);
};


