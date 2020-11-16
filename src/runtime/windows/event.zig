const system = @import("./system.zig");
const spinLoopHint = @import("../sync/sync.zig").core.atomic.spinLoopHint;

pub const Event = struct {
    key: u32 = undefined,

    pub fn wait(self: *Event) void {
        const key = @ptrCast(*align(4) const c_void, &self.key);
        switch (system.NtWaitForKeyedEvent(null, key, system.FALSE, null)) {
            system.STATUS_SUCCESS => {},
            else => unreachable,
        }
    }

    pub fn notify(self: *Event) void {
        const key = @ptrCast(*align(4) const c_void, &self.key);
        switch (system.NtReleaseKeyedEvent(null, key, system.FALSE, null)) {
            system.STATUS_SUCCESS => {},
            else => unreachable,
        }
    }

    pub fn yield(iteration: ?usize) bool {
        const iter = iteration orelse {
            _ = system.SleepEx(1, system.FALSE);
            return false;
        };

        if (iter < 4000) {
            spinLoopHint();
            return true;
        }

        return false;
    }
};
