const zap = @import(".../zap");
const atomic = zap.sync.atomic;

pub const Lock = extern struct {
    locked: bool = false,

    pub fn tryAcquire(self: *Lock) bool {
        return atomic.compareAndSwap(
            &self.locked,
            false,
            true,
            .acquire,
            .relaxed,
        ) == null;
    }

    pub fn acquire(self: *Lock) void {
        while (atomic.swap(&self.locked, true, .acquire))
            atomic.spinLoopHint();
    }

    pub fn release(self: *Lock) void {
        atomic.store(&self.locked, false, .release);
    }
};

pub const Event = extern struct {
    is_notified: bool,

    pub fn init(self: *Event) void {
        self.reset();
    }

    pub fn deinit(self: *Event) void {
        self.* = undefined;
    }

    pub fn reset(self: *Event) void {
        self.is_notified = false;
    }

    pub fn wait(self: *Event, deadline: ?u64) error{TimedOut}!void {
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

    pub fn notify(self: *Event) void {
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