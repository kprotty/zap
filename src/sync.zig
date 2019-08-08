// Event used for monitor
// Maybe mutex later to imitate golang?

const os = @import("os.zig");
const memory = @import("memory.zig");
const atomic = @import("atomic.zig");

pub const Event = struct {
    var wake: u32 = 1;
    value: u32,

    pub fn init(self: *Event) void {
        self.value = 0;
    }

    pub fn wait(self: *Event) void {
        const wake_ptr = memory.ptrCast(os.PVOID, &wake);
        const value_ptr = memory.ptrCast(os.PVOID, &self.value);
        while (@atomicLoad(@typeOf(self.value), &self.value, .Monotonic) == 0)
            _ = os.WaitOnAddress(value_ptr, wake_ptr, @sizeOf(@typeOf(self.value)), os.INFINITE);
    }

    pub fn signal(self: *Event) void {
        atomic.store(@typeOf(self.value), &self.value, 1, .Acquire);
        os.WakeByAddressSingle();
    }

    pub fn reset(self: *Event) void {
        atomic.store(@typeOf(self.value), &self.value, 0, .Release);
    }
};