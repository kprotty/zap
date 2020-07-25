const std = @import("std");

pub fn yield() void {
    _ = std.os.sched_yield() catch {};
}

pub fn sleep(nanoseconds: u64) void {
    std.time.sleep(nanoseconds);
}

pub const 