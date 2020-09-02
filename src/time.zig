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
const zap = @import("./zap.zig");

pub const TimeoutQueue = @import("./time/queue.zig").TimeoutQueue;

pub const os = core(zap.sync.os.Signal);
pub const task = core(zap.sync.task.Signal);

pub fn core(comptime Signal: type) type {
    return struct {
        pub const nanotime = Signal.nanotime;

        pub fn sleep(delay_ns: u64) void {
            var signal: Signal = undefined;
            signal.init();

            signal.timedWait(delay_ns) catch return signal.deinit();

            unreachable;
        }

        pub const Timer = extern struct {
            started: u64,

            pub fn start() Timer {
                return Timer{ .started = nanotime() };
            }

            pub fn read(self: Timer) u64 {
                return nanotime() - self.started;
            }

            pub fn reset(self: *Timer) void {
                self.started = nanotime();
            }

            pub fn lap(self: *Timer) u64 {
                const now = nanotime();
                const lap_time = now - self.started;
                self.started = now;
                return lap_time;
            }
        };
    };
}


