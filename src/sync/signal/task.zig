// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const zap = @import("../../zap.zig");

pub const Signal = extern struct {
    const EMPTY: usize = 0;
    const NOTIFIED: usize = 1;

    state: usize = EMPTY,

    pub fn init(self: *Signal) void {
        self.* = Signal{};
    }

    pub fn deinit(self: *Signal) void {
        self.* = undefined;
    }

    pub fn notify(self: *Signal) void {
        const state = @atomicRmw(
            usize,
            &self.state,
            .Xchg,
            NOTIFIED,
            .Release,
        );

        if (state == EMPTY or state == NOTIFIED)
            return;

        const task = @intToPtr(*zap.Task, state);
        task.schedule();
    }

    pub fn wait(self: *Signal) void {
        var task = zap.Task.init(@frame());
        
        suspend {
            if (@cmpxchgStrong(
                usize,
                &self.state,
                EMPTY,
                @ptrToInt(&task),
                .Release,
                .Acquire,
            )) |state| {
                if (state != NOTIFIED)
                    std.debug.panic("multiple waiters on the same signal", .{});
                task.scheduleNext();
            }
        }

        const state = @atomicLoad(usize, &self.state, .Acquire);
        if (state != NOTIFIED)
            std.debug.panic("waiter woken up when not notified", .{});

        @atomicStore(usize, &self.state, EMPTY, .Monotonic);
    }

    pub fn yield(iter: usize) bool {
        if (iter > 3)
            return false;

        const spin = @as(usize, 1) << @intCast(std.math.Log2Int(usize), iter);
        zap.sync.spinLoopHint(spin);
        return true;
    }
};