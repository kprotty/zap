const std = @import("std");
const zap = @import("zap");

const num_chans = 5000;

pub fn main() !void {
    try (try zap.Scheduler.runAsync(.{}, asyncMain, .{}));
}

fn asyncMain() !void {
    const allocator = std.heap.page_allocator;
    const frames = try allocator.alloc(@Frame(filter), num_chans);
    // defer allocator.free(frames);

    var gen_chan = Channel(u64).init(&[_]u64{});
    var gen = async generator(&gen_chan);
    var ch = &gen_chan;

    for (frames) |*frame| {
        const prime = ch.recv();
        var c1: *Channel(u64) = undefined;
        frame.* = async filter(ch, &c1, prime);
        ch = c1;
    }

    var i: usize = num_chans;
    while (i != 0) : (i -= 1) {
        _ = ch.recv();
    }
}

fn generator(ch: *Channel(u64)) void {
    var i: u64 = 2;
    while (true) : (i += 1) {
        ch.send(i);
    }
}

fn filter(in: *Channel(u64), out_chan: **Channel(u64), prime: u64) void {
    var chan = Channel(u64).init(&[_]u64{});
    const out = &chan;
    out_chan.* = out;

    while (true) {
        const i = in.recv();
        if (i % prime != 0) {
            out.send(i);
        }
    }
}

fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        const Waiter = struct {
            next: ?*Waiter,
            last: *Waiter,
            task: zap.Task,
            waker: *zap.Task,
            item: T,
        };

        lock: std.Mutex,
        senders: ?*Waiter,
        receivers: ?*Waiter,
        head: usize,
        tail: usize,
        buffer: []T,

        pub fn init(buffer: []T) Self {
            return Self{
                .lock = std.Mutex.init(),
                .senders = null,
                .receivers = null,
                .head = 0,
                .tail = 0,
                .buffer = buffer,
            };
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.tail == self.head);
            std.debug.assert(self.senders == null);
            std.debug.assert(self.receiver == null);
            self.* = undefined;
        }

        pub fn send(self: *Self, item: T) void {
            const held = self.lock.acquire();

            if (self.receivers) |waiter| {
                const receiver = waiter;
                self.receivers = receiver.next;
                held.release();

                var task = zap.Task.init(@frame());
                receiver.waker = &task;
                receiver.item = item;
                suspend receiver.task.scheduleNext(); 
                return;
            }

            if (self.tail -% self.head < self.buffer.len) {
                self.buffer[self.tail % self.buffer.len] = item;
                self.tail +%= 1;
                held.release();
                return;
            }

            var waiter: Waiter = undefined;
            waiter.task = zap.Task.init(@frame());
            waiter.item = item;
            waiter.next = null;
            waiter.last = &waiter;
            if (self.senders) |head| {
                head.last.next = &waiter;
                head.last = &waiter;
            } else {
                self.senders = &waiter;
            }
            suspend held.release();
        }

        pub fn recv(self: *Self) T {
            const held = self.lock.acquire();

            if (self.senders) |waiter| {
                const sender = waiter;
                self.senders = sender.next;
                held.release();

                const item = sender.item;
                sender.task.schedule();
                return item;
            }

            if (self.tail != self.head) {
                const item = self.buffer[self.head % self.buffer.len];
                self.head +%= 1;
                held.release();
                return item;
            }

            var waiter: Waiter = undefined;
            waiter.task = zap.Task.init(@frame());
            waiter.next = null;
            waiter.last = &waiter;
            if (self.receivers) |head| {
                head.last.next = &waiter;
                head.last = &waiter;
            } else {
                self.receivers = &waiter;
            }
            suspend held.release();

            waiter.waker.schedule();
            return waiter.item;
        }
    };
}