const atomic = @import("./atomic.zig");

pub const SpinEvent = extern struct {
    is_notified: bool,

    pub fn init(self: *SpinEvent) void {}
    pub fn deinit(self: *SpinEvent) void {}

    pub fn wait(self: *SpinEvent, deadline: ?u64, condition: anytype) error{TimedOut}!void {
        self.is_notified = false;

        if (!condition.wait()) {
            return;
        }

        while (true) {
            if (atomic.load(&self.is_notified, .acquire)) {
                return;
            }

            if (deadline) |deadline_ns| {
                const now = nanotime();
                if (now > deadline_ns)
                    return error.TimedOut;
            }

            atomic.spinLoopHint();
        }
    }

    pub fn notify(self: *SpinEvent) void {
        atomic.store(&self.is_notified, true, .release);
    }

    pub fn yield(iteration: ?usize) bool {
        const iter = iteration orelse {
            atomic.spinLoopHint();
            return false;
        };

        if (iter < 1000) {
            atomic.spinLoopHint();
            return true;
        }

        return false;
    }

    pub fn nanotime() u64 {
        return 0;
    }
};