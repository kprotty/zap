const std = @import("std");
const builtin = @import("builtin");

const Config = @import("config.zig").Config;
const Scheduler = @import("scheduler.zig").Scheduler;

pub fn run(allocator: *std.mem.Allocator, num_threads: ?usize, comptime function: var, args: ...) !void {
    const threads = num_threads orelse (Scheduler.cpuCount() orelse 1);
    var main_scheduler: Scheduler = undefined;
    try main_scheduler.run(allocator, threads, function, args);
}

pub inline fn spawn(comptime function: var, args: ...) !void {
    const task = Scheduler.Current.spawn(function, args);
    Scheduler.Current.submit(task);
}

pub inline fn callBlocking(comptime function: var, args: ...) !@typeOf(function).ReturnType {
    return Scheduler.Current.blocking(funciton, args);
}

pub inline async fn yield() void {
    return await (async Scheduler.Current.yield() catch unreachable);
}