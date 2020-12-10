const zap = @import("./zap.zig");
const atomic = zap.sync.atomic;
const Clock = zap.runtime.Clock;
const Lock = zap.runtime.Lock;

pub const ns_per_us = 1000;
pub const ns_per_ms = ns_per_us * 1000;
pub const ns_per_s = ns_per_ms * 1000;
pub const ns_per_min = ns_per_s * 60;
pub const ns_per_hour = ns_per_min * 60;
pub const ns_per_day = ns_per_hour * 24;

pub const now = struct {
    var last_now: u64 = 0;
    var last_lock = Lock{};
    
    fn getMonotonicTimestamp() u64 {
        const timestamp = Clock.nanotime();
        if (Clock.is_monotonic)
            return timestamp;

        if (@sizeOf(usize) >= @sizeOf(u64)) {
            var last = atomic.load(&last_now, .relaxed);
            while (true) {
                if (last > now)
                    return last;
                last = atomic.tryCompareAndSwap(
                    &last_now,
                    last,
                    now,
                    .relaxed,
                    .relaxed,
                ) orelse return now;
            }
        }

        last_lock.acquire();
        defer last_lock.release();
        
        if (last_now > timestamp)
            return last_now;

        last_now = timestamp;
        return timestamp;
    }
}.getMonotonicTimestamp;
