// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const zap = @import("./zap.zig");

pub const os = withContinuation(@import(""))

fn withContinuation(comptime Continuation: type) type {
    return struct {
        pub const Continuation = Continuation;

        pub const Lock = struct {
            lock: zap.core.sync.Lock = zap.core.sync.Lock{},

            pub fn acquire(self: *Lock) void {
                self.lock.acquire(Continuation);
            }

            pub fn release(self: *Lock) void {
                self.lock.release();
            }
        };
    };
}