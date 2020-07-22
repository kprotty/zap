const std = @import("std");
const windows = std.os.windows;
const KeyedEvent = @import("./event.zig").KeyedEvent;

pub fn yield() void {
    _ = windows.kernel32.SwitchToThread();
}

pub fn sleep(nanoseconds: u64) void {
    var stub: u32 = undefined;
    const key = @ptrCast(KeyedEvent.Key, &stub);
    KeyedEvent.wait(key, nanoseconds) catch |err| return;
    unreachable;
}

pub fn nanotime() u64 {
    
}