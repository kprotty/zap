const std = @import("std");
const sync = @import("../sync.zig");

pub const AutoResetEvent = extern struct {
    state: sync.atomic.Atomic(usize) = sync.atomic.Atomic(usize).init(UNSET),

    const UNSET = 0;
    const SET = 1;

    const Waiter = struct {
        aligned: void align(2) = undefined,
        waker: sync.Waker,
    };

    pub fn wait(self: *AutoResetEvent, comptime Futex: type) void {
        self.waitUntil(Futex, null) catch unreachable;
    }

    pub fn timedWait(self: *AutoResetEvent, comptime Futex: type, deadline: *Futex.Timestamp) error{TimedOut}!void {
        return self.waitUntil(Futex, deadline);
    }

    fn waitUntil(this: *AutoResetEvent, comptime Futex: type, deadline: ?*Futex.Timestamp) error{TimedOut}!void {
        const Future = struct {
            event: *AutoResetEvent,
            futex: Futex = Futex{},
            state: State = .checking,
            waiter: Waiter = Waiter{ .waker = sync.Waker{ .wakeFn = wake } },
            condition: sync.Condition = sync.Condition{ .isMetFn = isConditionMet },

            const Self = @This();
            const State = enum {
                checking,
                waiting,
                waited,
                cancelled,
            };

            fn wake(waker: *sync.Waker) void {
                const waiter = @fieldParentPtr(Waiter, "waker", waker);
                const self = @fieldParentPtr(Self, "waiter", waiter);
                self.futex.wake();
            }

            fn isConditionMet(condition: *sync.Condition) bool {
                const self = @fieldParentPtr(Self, "condition", condition);
                const event = self.event;
                
                const should_wait = switch (self.state) {
                    .checking => true,
                    .waiting => false,
                    .waited => unreachable, // condition checked when AutoResetEvent already waited
                    .cancelled => unreachable, // condition checked when AutoResetEvent was cancelled
                };

                if (should_wait) {
                    var state = event.state.load(.acquire);
                    while (true) {
                        if (state == SET) {
                            event.state.store(UNSET, .relaxed);
                            self.state = .waited;
                            return true;
                        }

                        if (state != UNSET) {
                            unreachable; // multiple waiters on the same AutoResetEvent
                        }

                        self.state = .waiting;
                        state = event.state.tryCompareAndSwap(
                            state,
                            @ptrToInt(&self.waiter),
                            .release,
                            .acquire,
                        ) orelse return false;
                    }
                }

                self.state = .cancelled;
                return event.state.compareAndSwap(
                    @ptrToInt(&self.waiter),
                    UNSET,
                    .acquire,
                    .acquire,
                ) == null;
            }
        };

        var future = Future{ .event = this };
        while (future.state == .checking or .state == .waiting) {
            if (!future.futex.wait(deadline, &future.condition) and deadline == null)
                unreachable; // Futex wait timed out when no deadline was provided
        }
        
        if (future.state == .cancelled)
            return error.TimedOut;
    }

    pub fn set(self: *AutoResetEvent) void {
        var state = self.state.load(.acquire);
        while (true) {
            state = switch (state) {
                SET => return,
                UNSET => self.state.tryCompareAndSwap(
                    state,
                    SET,
                    .release,
                    .acquire,
                ) orelse return,
                else => self.state.tryCompareAndSwap(
                    state,
                    UNSET,
                    .release,
                    .acquire,
                ) orelse {
                    const waiter = @intToPtr(*Waiter, state & ~@as(usize, SET));
                    waiter.waker.wake();
                    return;
                },
            };
        }
    }
};