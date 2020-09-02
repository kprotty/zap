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

pub fn main() !void {
    try (try (zap.Task.runAsync(.{}, asyncMain, .{})));
}

fn asyncMain() !void {
    var timer = zap.time.task.Timer.start();

    // t1 wait for 2s, t2 wait for 1s, t2 cancells t1 wait
    try testCancellation(
        2 * std.time.ns_per_s,
        1 * std.time.ns_per_s,
        true,
    );
    assertTimePassedWithError(
        timer.lap(), 
        1 * std.time.ns_per_s,
        50 * std.time.ns_per_ms,
    );

    // t1 wait for 2s, t2 wait for 1s
    try testCancellation(
        2 * std.time.ns_per_s,
        1 * std.time.ns_per_s,
        false,
    );
    assertTimePassedWithError(
        timer.lap(),
        2 * std.time.ns_per_s,
        50 * std.time.ns_per_ms,
    );

    // spawns {concurrency} threads which each wait for 1s, expect total wait to be around 1s
    const concurrency: usize = 100;
    try testMultiWait(
        concurrency,
        1 * std.time.ns_per_s,
    );
    assertTimePassedWithError(
        timer.lap(), 
        1 * std.time.ns_per_s,
        500 * std.time.ns_per_ms,
    );
}

fn assertTimePassedWithError(
    elapsed: u64,
    expected: u64,
    margin_of_error: u64,
) void {
    if (elapsed > expected + margin_of_error)
        std.debug.panic("time passed longer than expected", .{});
    if (elapsed < expected - margin_of_error)
        std.debug.panic("not enough expected time passed", .{});

    std.debug.warn("assertTimedPassed(elapsed={}ms, expected={}ms, error={}ms)\n", .{
        elapsed / std.time.ns_per_ms,
        expected / std.time.ns_per_ms,
        margin_of_error / std.time.ns_per_ms,
    });
}

/// Tests the ability for timers to wait indenpendently and potentially cancel
fn testCancellation(wait: u64, cancel_wait: u64, should_cancel: bool) !void {
    const Signal = zap.sync.task.Signal;

    var signal: Signal = undefined;
    signal.init();
    defer signal.deinit();

    const Canceller = struct {
        fn run(caller_signal: *Signal, wait_for: u64, cancel_caller_signal: bool) void {
            // run concurrently
            suspend {
                var task = zap.Task.from(@frame());
                task.schedule();
            }

            zap.time.task.sleep(wait_for);

            if (cancel_caller_signal)
                caller_signal.notify();
        }
    };

    var cancel_frame = async Canceller.run(&signal, cancel_wait, should_cancel);
    defer await cancel_frame;

    if (signal.timedWait(wait)) |_| {
        if (!should_cancel)
            std.debug.panic("main signal was cancelled when it shouldn't have been\n", .{});

    } else |timed_out| {
        if (should_cancel)
            std.debug.panic("main signal wasn't cancelled when it should have been\n", .{});
    }    
}

/// Test the concurrent sleeping of multiple tasks
fn testMultiWait(concurrency: usize, wait: u64) !void {
    const Waiter = struct {
        fn run(wait_for: u64) void {
            zap.Task.runConcurrently();
            zap.time.task.sleep(wait_for);
        }
    };
    
    const allocator = zap.Task.getAllocator();
    const frames = try allocator.alloc(@Frame(Waiter.run), concurrency);
    defer allocator.free(frames);

    for (frames) |*frame|
        frame.* = async Waiter.run(wait);
    for (frames) |*frame|
        await frame;
}