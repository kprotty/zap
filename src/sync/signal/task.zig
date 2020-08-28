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

pub const Signal = struct {
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
        return self.notifyFast(false);
    }

    pub fn notifyHandoff(self: *Signal) void {
        return self.notifyFast(true);
    }

    fn notifyFast(self: *Signal, handoff: bool) void {
        const state = @atomicRmw(usize, &self.state, .Xchg, NOTIFIED, .Release);
        if (state != EMPTY)
            self.notifySlow(handoff, state);
    }

    fn notifySlow(self: *Signal, handoff: bool, state: usize) void {
        @setCold(true);

        if (state == NOTIFIED)
            std.debug.panic("Signal.notify() when already notified\n", .{});

        const waiter = @intToPtr(*zap.Task, state);
        if (!handoff)
            return waiter.schedule();

        suspend {
            var task = zap.Task.init(@frame());
            waiter.scheduleNext();
            task.schedule();
        }
    }

    pub fn wait(self: *Signal) void {
        const state = @atomicLoad(usize, &self.state, .Acquire);

        if (state != NOTIFIED)
            self.waitSlow();

        @atomicStore(usize, &self.state, EMPTY, .Monotonic);
    }

    fn waitSlow(self: *Signal) void {
        @setCold(true);

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
                    std.debug.panic("Signal.wait() on more than one task", .{});
                resume @frame();
            } 
        }
    }

    const OsSignal = @import("./os.zig").Signal;

    pub const canYield = OsSignal.canYield;

    pub const yield = OsSignal.yield;
};
