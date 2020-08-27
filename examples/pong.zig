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

pub fn main() !void {
    try (try (zap.Task.runAsync(.{}, asyncMain, .{})));
}

fn asyncMain() !void {
    const allocator = zap.Task.getAllocator();
    const frames = try allocator.alloc(@Frame(asyncWorker), num_tasks);
    defer allocator.free(frames);

    var counter: usize = 0;
    var event = zap.Task.init(@frame());
    
    suspend {
        var batch = zap.Task.Batch{};
        for (frames) |*frame|
            frame.* = async asyncWorker(&batch, &event, &counter);
        batch.schedule();
    }

    const completed = @atomicLoad(usize, &counter, .Monotonic);
    if (completed != num_tasks)
        std.debug.panic("Only {}/{} tasks completed\n", .{completed, num_tasks});
}

fn asyncWorker(batch: *zap.Task.Batch, event: *zap.Task, counter: *usize) void {
    suspend {
        var task = zap.Task.init(@frame());
        batch.push(&task);
    }

    const Channel = zap.sync.Channel;
    const Pong = struct {
        fn run(c1: *Channel(void), c2: *Channel(void)) void {
            suspend {
                var task = zap.Task.init(@frame());
                task.schedule();
            }

            _ = c1.get() catch unreachable;
            c2.put({}) catch unreachable;
        }
    };

    var c1 = Channel(void).init(&[0]void{});
    defer c1.deinit();

    var c2 = Channel(void).init(&[0]void{});
    defer c2.deinit();

    var pong = async Pong.run(&c1, &c2);
    c1.put({}) catch unreachable;
    _ = c2.get() catch unreachable;
    _ = await pong;

    suspend {
        const completed = @atomicRmw(usize, counter, .Add, 1, .Monotonic);
        if (completed + 1 == num_tasks)
            event.scheduleNext();
    }
}

