const std = @import("std");
const task = @import("./src/task.zig");

const num_forks: usize = 10;
const entry_result: usize = 42;

pub fn main() !void {
    const result = try task.Scheduler.call(.{}, entry, .{});
    std.debug.assert(result == entry_result);
}

fn entry() usize {
    std.debug.warn("Parent task begin with {} forks\n", .{num_forks});
    defer std.debug.warn("Parent task end\n", .{});

    var forks: [num_forks]@Frame(fork) = undefined;
    for (forks) |*f, id|
        f.* = async fork(id);
    for (forks) |*f, id| {
        const result = await f;
        std.debug.assert(result == id); 
    }

    return entry_result;
}

fn fork(id: usize) usize {
    task.Task.yield();
    const thread_id = std.Thread.getCurrentId();
    std.debug.warn("Hello from fork {} on thread {}\n", .{id, thread_id});
    return id;
}