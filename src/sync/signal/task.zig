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

    pub inline fn notify(self: *Signal) void {
        return self.notifyFast(false);
    }

    pub inline fn notifyHandoff(self: *Signal) void {
        return self.notifyFast(true);
    }

    fn notifyFast(self: *Signal, comptime handoff: bool) void {
        const state = @atomicRmw(
            usize,
            &self.state,
            .Xchg,
            NOTIFIED,
            .Release,
        );

        if (state > NOTIFIED)
            self.notifySlow(state, handoff);
    }

    fn notifySlow(self: *Signal, state: usize, comptime handoff: bool) void {
        @setCold(true);

        const task = @intToPtr(*zap.Task, state);
        if (!handoff)
            return task.schedule();

        suspend {
            var me = zap.Task.from(@frame());
            var batch = zap.Task.Batch.from(&me);

            const thread = zap.Task.getCurrentThread();
            if (thread.scheduleNext(task)) |old_next|
                batch.pushFront(old_next);

            thread.schedule(batch);
        }
    }

    pub fn wait(self: *Signal) void {
        std.debug.assert(self.tryWait(null));
    }

    pub fn timedWait(self: *Signal, timeout: u64) error{TimedOut}!void {
        if (!self.tryWait(timeout))
            return error.TimedOut;
    }

    fn tryWait(self: *Signal, timeout: ?u64) bool {
        var deadline: ?u64 = null;
        if (timeout) |timeout_ns| {
            if (timeout_ns == 0)
                return false;
            deadline = nanotime() + timeout_ns;
        }
        
        const OnTimeout = struct {
            fn run(task: *zap.Task, signal: *Signal) void {
                suspend task.* = zap.Task.from(@frame());

                var state = @atomicLoad(usize, &signal.state, .Monotonic);
                while (true) {
                    if (state == EMPTY or state == NOTIFIED)
                        return;
                    state = @cmpxchgWeak(
                        usize,
                        &signal.state,
                        state,
                        EMPTY,
                        .Acquire,
                        .Monotonic,
                    ) orelse break;
                }

                @setRuntimeSafety(false);
                const waiter = @intToPtr(*zap.Task, state);
                waiter.schedule();
            }
        };

        var task = zap.Task.from(@frame());
        var frame_task: zap.Task = undefined;
        var frame: @Frame(OnTimeout.run) = undefined;
        var timer: zap.Task.Reactor.Timer = undefined;

        suspend {
            if (@cmpxchgStrong(
                usize,
                &self.state,
                EMPTY,
                @ptrToInt(&task),
                .Release,
                .Acquire,
            )) |_| {
                deadline = null;
                task.scheduleNext();
            } else if (deadline) |deadline_ns| {
                frame = async OnTimeout.run(&frame_task, self);
                timer.scheduleAfter(&frame_task, deadline_ns);
            }
        }

        if (deadline != null and !timer.cancel()) {
            await frame;
        }

        const state = @atomicLoad(usize, &self.state, .Acquire);
        if (state == EMPTY)
            return false;

        if (state != NOTIFIED)
            std.debug.panic("Signal waiter scheduled when not notified", .{});
        @atomicStore(usize, &self.state, EMPTY, .Monotonic);
        return true;
    }

    pub fn yield(iter: usize) bool {
        if (iter > 3)
            return false;

        const spin = @as(usize, 1) << @intCast(std.math.Log2Int(usize), iter);
        zap.sync.spinLoopHint(spin);
        return true;
    }

    pub fn nanotime() u64 {
        return zap.sync.os.Signal.nanotime();
    }
};