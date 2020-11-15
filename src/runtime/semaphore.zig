const std = @import("std");
const Lock = @import("./lock.zig").Lock;

pub const Semaphore = struct {
    lock: Lock = Lock{},
    counter: usize = 0,
    waiters: Waiter.Queue = Waiter.Queue{},

    const Waiter = struct {
        next: ?*Waiter,
        last: *Waiter,
        event: std.ResetEvent,

        const Queue = struct {
            head: ?*Waiter = null,

            fn push(self: *Queue, waiter: *Waiter) void {
                waiter.next = null;
                if (self.head) |head| {
                    head.last.next = waiter;
                    head.last = waiter;
                } else {
                    waiter.last = waiter;
                    self.head = waiter;
                }
            }

            fn pop(self: *Queue) ?*Waiter {
                const waiter = self.head orelse return null;
                self.head = waiter.next;
                if (self.head) |head|
                    head.last = waiter.last;
                return waiter;
            }
        };
    };

    pub fn wait(self: *Semaphore) void {
        var next_waiter: ?*Waiter = undefined;
        defer if (next_waiter) |waiter|
            waiter.event.set();

        var waiter: Waiter = undefined;
        waiter.event = std.ResetEvent.init();
        defer waiter.event.deinit();

        while (true) {
            self.lock.acquire();

            if (self.counter > 0) {
                self.counter -= 1;
                next_waiter = self.waiters.pop();
                self.lock.release();
                break;
            }

            self.waiters.push(&waiter);
            self.lock.release();
            waiter.event.wait();
            waiter.event.reset();
        }
    }

    pub fn notify(self: *Semaphore, count: usize) void {
        if (count == 0)
            return;

        const next_waiter = blk: {
            self.lock.acquire();
            defer self.lock.release();

            self.counter += count;
            break :blk self.waiters.pop();
        };

        if (next_waiter) |waiter|
            waiter.event.set();
    }
};