const zap = @import(".../zap.zig");
const atomic = zap.sync.atomic;
const Clock = zap.time.OsClock;
const futex = @import("./futex.zig");

pub const Lock = futex.Lock(Futex);
pub const Event = futex.Event(Futex);

const Futex = struct {
    pub fn wait(ptr: *const i32, cmp: i32, deadline: ?u64) error{TimedOut}!void {

    }

    pub fn wake(ptr: *const i32) void {

    }

    pub fn yield(iteration: ?usize) bool {

    }

    pub fn nanotime() u64 {
        return Clock.nanoTime();
    }
};