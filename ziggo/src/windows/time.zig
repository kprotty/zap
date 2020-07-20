const std = @import("std");
const windows = @import("./windows.zig");

threadlocal var time_state = TimeState{};
const TimeState = struct {
    last_now: u64 = 0,
    first_now: u64 = 0,
};

pub fn nanotime() u64 {
    const frequency = Frequency.get();
    var now = windows.QueryPerformanceCounter();
    
    var state = time_state;
    defer time_state = state;

    if (state.first_now == 0)
        state.first_now = now;

    if (state.last_now > now) {
        now = state.last_now;
    } else {
        state.last_now = now;
    }

    const duration = now -% state.first_now;
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