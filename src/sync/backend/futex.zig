const zap = @import("../../zap.zig");
const atomic = zap.sync.atomic;

pub fn Lock(comptime Futex: type) type {
    return extern struct {
        state: i32 = UNLOCKED,

        const UNLOCKED: i32 = 0;
        const LOCKED: i32 = 1;
        const WAITING: i32 = 2;

        const Self = @This();

        pub fn tryAcquire(self: *Self) bool {
            return atomic.compareAndSwap(
                &self.state,
                UNLOCKED,
                LOCKED,
                .acquire,
                .relaxed,
            ) == null;
        }

        pub fn acquire(self: *Self) void {
            const state = atomic.swap(&self.state, LOCKED, .acquire);
            if (state != UNLOCKED)
                self.acquireSlow(state);
        }

        fn acquireSlow(self: *Self, current_state: i32) void {
            @setCold(true);

            var spin: usize = 0;
            var wait_state = current_state;

            while (true) {    
                while (true) {
                    switch (atomic.load(&self.state, .relaxed)) {
                        UNLOCKED => _ = atomic.tryCompareAndSwap(
                            &self.state,
                            UNLOCKED,
                            wait_state,
                            .acquire,
                            .relaxed,
                        ) orelse return,
                        LOCKED => {},
                        WAITING => break,
                        else => unreachable,
                    }

                    if (Futex.yield(spin)) {
                        spin +%= 1;
                    } else {
                        break;
                    }
                }

                const state = atomic.swap(&self.state, WAITING, .acquire);
                if (state == UNLOCKED)
                    return;

                spin = 0;
                wait_state = WAITING;
                Futex.wait(&self.state, WAITING, null) catch unreachable;
            }
        }

        pub fn release(self: *Self) void {
            switch (atomic.swap(&self.state, UNLOCKED, .release)) {
                UNLOCKED => unreachable, // unlocked an unlocked Lock
                LOCKED => {},
                WAITING => self.releaseSlow(),
                else => unreachable,
            }
        }

        fn releaseSlow(self: *Self) void {
            @setCold(true);

            Futex.wake(&self.state);
        }
    };
}

pub fn Event(comptime Futex: type) type {
    @compileError("TODO");
}