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
const WaitGroup = zap.sync.task.WaitGroup;

pub fn main() !void {
    try (try (zap.Task.runAsync(.{}, asyncMain, .{})));
}

fn asyncMain() !void {
    const allocator = zap.Task.getAllocator();
    const frames = try allocator.alloc(@Frame(waiter), 5);
    defer allocator.free(frames);

    var wait_group = WaitGroup{};
    for (frames) |*frame, id| {
        wait_group.add(1);
        frame.* = async waiter(&wait_group, id + 1, 1 * std.time.ns_per_s);
    }

    wait_group.wait();
    for (frames) |*frame|
        await frame;
}

fn waiter(wait_group: *WaitGroup, id: usize, sleep_for: u64) void {
    suspend {
        var task = zap.Task.from(@frame());
        task.schedule();
    }

    std.debug.warn("{} sleeping for {}ms\n", .{id, sleep_for / std.time.ns_per_ms});
    zap.time.task.sleep(sleep_for);

    std.debug.warn("{} woke up\n", .{id});
    wait_group.done();
}