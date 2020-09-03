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

const num_tasks = 100 * 1000;
const num_yields = 200;

pub fn main() !void {
    try (try (zap.Task.runAsync(.{}, asyncMain, .{})));
}

fn asyncMain() !void {
    const allocator = zap.Task.getAllocator();
    const frames = try allocator.alloc(@Frame(asyncWorker), num_tasks);
    defer allocator.free(frames);

    var wait_group = WaitGroup{};
    var batch = zap.Task.Batch{};

    wait_group.add(num_tasks);
    for (frames) |*frame|
        frame.* = async asyncWorker(&batch, &wait_group);
    batch.schedule();

    wait_group.wait();
    for (frames) |*frame|
        await frame;
}

fn asyncWorker(batch: *zap.Task.Batch, wait_group: *WaitGroup) void {
    suspend {
        var task = zap.Task.from(@frame());
        batch.push(&task);
    }

    var i: usize = num_yields;
    while (i != 0) : (i -= 1) {
        //zap.Task.yield();
        zap.time.task.sleep(1 * std.time.ns_per_ms);
    }

    wait_group.done();
}