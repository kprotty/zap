const std = @import("std");
const TP = @import("ThreadPool.zig");

const Pool = @This();

run_queue: Batch = .{},

pub const Config = TP.Config;

pub fn init(_: Config) Pool {
    return .{};
}

pub const Runnable = TP.Runnable;

pub const Batch = TP.Batch;

pub fn schedule(self: *Pool, batch: Batch) void {
    self.run_queue.push(batch);
}

pub fn shutdown(_: *Pool) void {}
pub fn join(_: *Pool) void {}

pub fn run(self: *Pool) void {
    while (self.run_queue.pop()) |runnable|
        (runnable.runFn)(runnable);
}