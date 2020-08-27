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

const num_tasks = 100 * 1000;
const num_yields = 200;

pub fn main() !void {
    try (try (zap.Task.runAsync(.{}, asyncMain, .{})));
}

fn asyncMain() !void {
    const allocator = zap.Task.getAllocator();
    const frames = try allocator.alloc(@Frame(asyncWorker), num_tasks);
    defer allocator.free(frames);

    var counter: usize = num_tasks;
    var event = zap.Task.init(@frame());
    
    suspend {
        var batch = zap.Task.Batch{};
        for (frames) |*frame|
            frame.* = async asyncWorker(&batch, &event, &counter);
        batch.schedule();
    }

    const completed = num_tasks - @atomicLoad(usize, &counter, .Monotonic);
    if (completed != num_tasks)
        std.debug.panic("Only {}/{} tasks completed\n", .{completed, num_tasks});
}

fn asyncWorker(batch: *zap.Task.Batch, event: *zap.Task, counter: *usize) void {
    suspend {
        var task = zap.Task.init(@frame());
        batch.push(&task);
    }

    var i: usize = num_yields;
    while (i != 0) : (i -= 1) {
        zap.Task.yield();
    }

    suspend {
        const completed = @atomicRmw(usize, counter, .Sub, 1, .Monotonic);
        if (completed - 1 == 0)
            event.scheduleNext();
    }
}