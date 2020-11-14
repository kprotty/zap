const std = @import("std");
const Lock = @import("./runtime/lock.zig").Lock;

pub const nanosecond = 1;
pub const microsecond = nanosecond * 1000;
pub const millisecond = microsecond * 1000;
pub const second = millisecond * 1000;
pub const minute = second * 60;
pub const hour = minute * 60;

pub fn now() u64 {
    const Clock = struct {
        var init_lock = Lock{};
        var is_init: bool = false;
        var timer: std.time.Timer = undefined;

        fn getTimer() *std.time.Timer {
            if (@atomicLoad(bool, &is_init, .SeqCst))
                return &timer;

            init_lock.acquire();
            defer init_lock.release();

            if (@atomicLoad(bool, &is_init, .SeqCst))
                return &timer;

            timer = std.time.Timer.start() catch unreachable;
            @atomicStore(bool, &is_init, true, .SeqCst);

            return &timer;
        }
    };

    return Clock.getTimer().read();
}