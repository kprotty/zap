const std = @import("std");
const windows = @import("./windows.zig");
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

pub const nanotime = Nanotime.timestamp;

const Nanotime = struct {
    var freq: u64 = 0;
    var last_now: u64 = 0;
    var first_now: u64 = 0;

    fn timestamp() u64 {
        if (@typeInfo(usize).Int.bits < 64)
            return timestamp32();

        var frequency = @atomicLoad(u64, &freq, .Monotonic);
        if (frequency == 0) {
            frequency = windows.QueryPerformanceFrequency();
            @atomicStore(u64, &freq, frequency, .Monotonic);
        }

        var now = windows.QueryPerformanceCounter();
        var first = @atomicLoad(u64, &first_now, .Monotonic);
        if (first == 0) {
            first = @cmpxchgStrong(
                u64,
                &first_now,
                first,
                now,
                .Monotonic,
                .Monotonic,
            ) orelse now;
        }

        var last = @atomicLoad(u64, &last_now, .Monotonic);
        while (true) {
            if (last > now) {
                now = last;
                break;
            }
            last = @cmpxchgWeak(
                u64,
                &last_now,
                last,
                now,
                .Monotonic,
                .Monotonic,
            ) orelse break;
        }

        const counter = (now - first) * std.time.ns_per_s;
        return @divFloor(counter, frequency);
    }

    var freq_state: u32 = 0;
    var ts_lock: usize = 0;

    fn timestamp32() u64 {
        const frequency = blk: {
            var state = @atomicLoad(u32, &freq_state, .Acquire);
            if (state == 2)
                break :blk freq;
            const f = windows.QueryPerformanceFrequency();
            if (@cmpxchgStrong(u32, &freq_state, 0, 1, .Monotonic, .Monotonic) == null) {
                freq = f;
                @atomicStore(u32, &freq_state, 2, .Release); 
            }
            break :blk f;
        };
        
        if (@cmpxchgWeak(usize, &ts_lock, 0, 1, .Acquire, .Monotonic)) |current_lock| {
            var lock = current_lock;
            while (true) {
                while (lock != 0) {
                    windows.kernel32.Sleep(1);
                    lock = @atomicLoad(usize, &ts_lock, .Monotonic);
                }
                lock = @cmpxchgWeak(
                    usize,
                    &ts_lock,
                    lock,
                    1,
                    .Acquire,
                    .Monotonic,
                ) orelse break;
            }
        }

        var now = windows.QueryPerformanceCounter();
        const first = first_now;
        if (first == 0)
            first_now = now;

        const last = last_now;
        if (now > last) {
            last_now = now;
        } else {
            now = last;
        }

        @atomicStore(usize, &ts_lock, 0, .Release);
        const counter = (now - first) * std.time.ns_per_s;
        return @divFloor(counter, frequency);
    }

};