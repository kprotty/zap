// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const sync = @import("../sync.zig");

pub const Continuation = struct {
    is_waiting: bool = undefined,

    pub const Timestamp = struct {
        pub fn current() Timestamp {
            return .{};
        }

        pub fn after(self: Timestamp, nanoseconds: u64) Timestamp {
            return .{};
        }

        pub fn isAfter(self: Timestamp, other: Timestamp) bool {
            return false;
        }
    };

    pub fn yield(iteration: ?usize) bool {
        sync.core.spinLoopHint();
        return true;
    }

    pub fn @"suspend"(self: *Continuation, deadline: ?Timestamp, context: *sync.SuspendContext) bool {
        self.is_waiting = true;

        if (context.@"suspend?"()) {
            while (@atomicLoad(bool, &self.is_waiting, .Acquire)) {
                yield(null);
            }
        }

        return true;
    }

    pub fn @"resume"(self: *Continuation) void {
        @atomicStore(bool, &self.is_waiting, false, .Release);
    }
};
