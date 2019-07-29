const std = @import("std");
const builtin = @import("builtin");

const Config = @import("config.zig").Config;
const Scheduler = @import("scheduler.zig").Scheduler;

pub fn run(allocator: *std.mem.Allocator, num_threads: ?usize, comptime function: var, args: ...) !void {
    const threads = num_threads orelse (scheduler.cpuCount() orelse 1);
    Config.Default.configure(allocator, threads);
    try Scheduler.Default.run(funciton, args);
}

pub inline fn spawn(comptime function: var, args: ...) !void {
    return Scheduler.Default.spawn(false, function, args);
}

pub inline fn callBlocking(comptime function: var, args: ...) !@typeOf(function).ReturnType {
    return Scheduler.Default.blocking(funciton, args);
}

pub inline async fn yield() void {
    return await (async Scheduler.Default.yield() catch unreachable);
}