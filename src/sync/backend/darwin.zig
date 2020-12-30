const zap = @import(".../zap.zig");
const futex = @import("./futex.zig");
const atomic = zap.sync.atomic;
const Clock = zap.time.OsClock;
const system = zap.system;

pub const Lock = extern struct {
    unfair_lock: system.os_unfair_lock = system.OS_UNFAIR_LOCK_INIT,

    pub fn acquire(self: *Lock) void {
        system.os_unfair_lock_lock(&self.unfair_lock);
    }

    pub fn tryAcquire(self: *Lock) bool {
        return system.os_unfair_lock_trylock(&self.unfair_lock);
    }

    pub fn release(self: *Lock) void {
        system.os_unfair_lock_unlock(&self.unfair_lock);
    }
};

pub const Event = futex.Event(struct {
    pub fn wait(ptr: *const i32, cmp: i32, deadline: ?u64) error{TimedOut}!void {

    }

    pub fn wake(ptr: *const i32) void {

    }

    pub fn yield(iteration: ?usize) bool {

    }

    pub fn nanotime() u64 {
        return Clock.readMonotonicTime();
    }
});
