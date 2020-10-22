// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const sync = @import("../sync.zig");

pub const Continuation = struct {
    is_waiting: bool = undefined,

    pub const Timestamp = @import("./os.zig").Continuation.Timestamp;

    pub fn yield(iteration: ?usize) bool {
        sync.core.spinLoopHint();
        return false;
    }

    pub fn @"suspend"(self: *Continuation, deadline: ?Timestamp, context: *sync.SuspendContext) bool {

        if (context.@"suspend?"()) {
            
    }

    pub fn @"resume"(self: *Continuation) void {
        
    }
};
