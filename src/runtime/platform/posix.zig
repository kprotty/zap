const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const os = std.os;

pub fn nanotime() u64 {
    if (comptime std.Target.current.isDarwin()) {
        const OnceInit = struct {
            var frequency = std.lazyInit(os.darwin.mach_timebase_info_data);
        };
        const frequency = OnceInit.frequency.get() orelse freq: {
            os.darwin.mach_timebase_info(&OnceInit.frequency.data);
            break :freq &OnceInit.frequency.data;
        };
        const clock = os.darwin.mach_absolute_time();
        return @divFloor(clock * frequency.numer, frequency.denom);
        
    } else {
        var ts: os.timespec = undefined;
        os.clock_gettime(os.CLOCK_MONOTONIC, &ts) catch unreachable;
        return @intCast(u64, ts.tv_sec) * std.time.second + @intCast(u64, ts.tv_nsec);
    }
}