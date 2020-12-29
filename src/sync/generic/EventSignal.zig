const zap = @import(".../zap");
const builtin = zap.builtin;
const atomic = zap.sync.atomic;

pub const EventSignal = extern struct {
    ptr: usize = EMPTY,
    
    const EMPTY: usize = 0;
    const NOTIFIED: usize = 1;
    const Waiter = struct {
        wakeFn: fn(*Waiter) void,
    };

    pub fn wait(self: *EventSignal, comptime Event: type) void {
        return self.tryWait(Event, null) catch unreachable;
    }

    pub fn tryWaitFor(self: *EventSignal, comptime Event: type, duration: u64) error{TimedOut}!void {
        return self.tryWaitUntil(Event, Event.nanotime() + duration);
    }

    pub fn tryWaitUntil(self: *EventSignal, comptime Event: type, deadline: u64) error{TimedOut}!void {
        return self.tryWait(Event, deadline);
    }

    fn tryWait(self: *EventSignal, comptime Event: type, deadline: ?u64) error{TimedOut}!void {
        switch (atomic.load(&self.ptr, .acquire)) {
            EMPTY => {},
            NOTIFIED => return,
            else => unreachable, // multiple waiters
        }

        var event_waiter: struct {
            event: Event = undefined,
            waiter: Waiter = .{ .wakeFn = wakeFn },

            fn wakeFn(waiter: *Waiter) void {
                const this = @fieldParentPtr(@This(), "waiter", waiter);
                this.event.notify();
            }
        } = .{};

        const event = &event_waiter.event;
        event.init();
        defer event.deinit();

        const WaitCondition = struct {
            signal: ?*EventSignal,
            waiter: *Waiter,

            pub fn wait(this: @This()) bool {
                const signal = this.signal orelse return true;
                return atomic.compareAndSwap(
                    &signal.ptr,
                    EMPTY,
                    @ptrToInt(this.waiter),
                    .release,
                    .acquire,
                ) == null;
            }
        };

        var timed_out = false;
        event.wait(deadline, WaitCondition{
            .signal = self,
            .waiter = &event_waiter.waiter,
        }) catch {
            timed_out = true;
        };

        if (timed_out) {
            const waiter = &event_waiter.waiter;
            const ptr = atomic.compareAndSwap(
                &self.ptr,
                @ptrToInt(waiter),
                EMPTY,
                .release,
                .acquire,
            ) orelse return error.TimedOut;

            if (ptr != NOTIFIED)
                unreachable;

            event.wait(null, WaitCondition{
                .signal = null,
                .waiter = waiter,
            }) catch unreachable;
        }
    }

    pub fn notify(self: *EventSignal) void {
        switch (atomic.swap(&self.ptr, NOTIFIED, .acq_rel)) {
            EMPTY => {},
            NOTIFIED => unreachable,
            else => |waiter_ptr| {
                const waiter = @intToPtr(*Waiter, waiter_ptr);
                (waiter.wakeFn)(waiter);
            },
        }
    }
}