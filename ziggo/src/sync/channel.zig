const std = @import("std");
const GenericLock = @import("./lock.zig").Lock;

pub fn Channel(
    comptime AutoResetEvent: type,
    comptime Lock: type,
    comptime T: type,
) type {
    return struct {
        const Self = @This();
        
        const Waiter = struct {
            event: AutoResetEvent,
            next: ?*Waiter,
            last: *Waiter,
            value: T,
        };

        lock: Lock,
        getters: ?*Waiter,
        putters: ?*Waiter,
        buffer: []T,
        head: usize,
        tail: usize,

        pub fn init(self: *Self, buffer: []T) void {
            self.* = Self{
                .lock = Lock.init(),
                .getters = null,
                .putters = null,
                .buffer = buffer,
                .head = 0,
                .tail = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.getters == null);
            std.debug.assert(self.putters == null);
            self.lock.deinit();
            self.* = undefined;
        }

        pub fn put(self: *Self, value: T) void {
            self.lock.acquire();

            if (self.getters) |waiter| {
                const w = waiter;
                self.getters = waiter.next;
                w.value = value;
                self.lock.release();
                w.event.notify();
                return;
            }

            if (self.tail -% self.head < self.buffer.len) {
                self.buffer[self.tail] = value;
                self.tail +%= 1;
                if (self.tail >= self.buffer.len)
                    self.tail = 0;
                self.lock.release();
                return;
            }

            var waiter: Waiter = undefined;
            waiter.next = null;
            waiter.last = &waiter;
            waiter.value = value;
            waiter.event.init();

            if (self.putters) |head| {
                const last = head.last;
                head.last = &waiter;
                last.next = &waiter;
            } else {
                self.putters = &waiter;
            }
            
            self.lock.release();
            waiter.event.wait();
            waiter.event.deinit();
        }

        pub fn get(self: *Self) T {
            self.lock.acquire();

            if (self.putters) |waiter| {
                const w = waiter;
                self.putters = waiter.next;
                const value = w.value;
                self.lock.release();
                w.event.notify();
                return value;
            }

            if (self.tail -% self.head > 0) {
                const value = self.buffer[self.head];
                self.head +%= 1;
                if (self.head >= self.buffer.len)
                    self.head = 0;
                self.lock.release();
                return value;
            }

            var waiter: Waiter = undefined;
            waiter.next = null;
            waiter.last = &waiter;
            waiter.event.init();

            if (self.getters) |head| {
                const last = head.last;
                head.last = &waiter;
                last.next = &waiter;
            } else {
                self.getters = &waiter;
            }
            
            self.lock.release();
            waiter.event.wait();
            waiter.event.deinit();
            return waiter.value;
        }

        pub fn getOrNull(self: *Self) ?T {
            self.lock.acquire();

            if (self.putters) |waiter| {
                const w = waiter;
                self.putters = waiter.next;
                const value = w.value;
                self.lock.release();
                w.event.notify();
                return value;
            }

            if (self.tail -% self.head > 0) {
                const value = self.buffer[self.head];
                self.head +%= 1;
                if (self.head >= self.buffer.len)
                    self.head = 0;
                self.lock.release();
                return value;
            }

            self.lock.release();
            return null;
        }
    };
}