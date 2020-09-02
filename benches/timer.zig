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
const zap = @import("zap");
const Signal = zap.sync.task.Signal;

pub fn main() !void {
    try (try (zap.Task.runAsync(.{}, asyncMain, .{})));
}

fn asyncMain() !void {
    var signal: Signal = undefined;
    signal.init();
    defer signal.deinit();

    var cancel_frame = async canceller(&signal);

    std.debug.warn("waiting on signal\n", .{});
    const notified = signal.timedWait(3 * std.time.ns_per_s);

    if (notified) |_| {
        std.debug.warn("signal was notified\n", .{});
    } else |_| {
        std.debug.warn("signal timed out\n", .{});
    }

    await cancel_frame;
}

fn canceller(signal: *Signal) void {
    suspend {
        var task = zap.Task.from(@frame());
        task.schedule();
    }

    std.debug.warn("sleeping to notify\n", .{});
    zap.time.task.sleep(1 * std.time.ns_per_s);

    std.debug.warn("cancelling\n", .{});
    // signal.notify();
}