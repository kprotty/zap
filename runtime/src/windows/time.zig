const std = @import("std");
const windows = @import("./windows.zig");

threadlocal var last_now: u64 = 0;
threadlocal var first_now: u64 = 0;

pub fn nanotime() u64 {
    const frequency = Frequency.get();
    var now = windows.QueryPerformanceCounter();
    if (first_now == 0)
        first_now = now;

    if (last_now > now) {
        now = last_now;
    } else {
        last_now = now;
    }
    const duration = now -% first_now;
    return @divFloor(duration * std.time.ns_per_s, frequency);
}

const Frequency = struct {
    const State = enum(u8) {
        Uninit,
        Creating,
        Ready,
    };

    var state: State = .Uninit;
    var frequency: u64 = undefined;
    
    /// Fast-path to get the global performance frequency.
    fn get() u64 {
        if (@atomicLoad(State, &state, .Acquire) == .Ready)
            return frequency;
        return getSlow();
    }

    /// Slow-path to get the performance frequency.
    /// Uses racy caching since fetching the frequency is cheaper than blocking synchronization.
    fn getSlow() u64 {
        @setCold(true);
        var new_frequency = windows.QueryPerformanceFrequency();
        if (@cmpxchgStrong(State, &state, .Uninit, .Creating, .Monotonic, .Monotonic) == null) {
            frequency = new_frequency;
            @atomicStore(State, &state, .Ready, .Release);
        }
        return new_frequency;
    }
};
