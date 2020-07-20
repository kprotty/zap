// A concurrent prime sieve
// Note: this would not be the recommended way to implement a
// concurrent prime sieve in Zig; this implementation is intended
// to serve as a direct port of the reference Go code.

const std = @import("std");
const zap = @import("zap");

const N = 500;

// Uncomment to use std.event.Loop
// pub const io_mode = .evented;
const use_event_loop = @hasDecl(@import("root"), "io_mode");

const Channel = 
    if (use_event_loop) std.event.Channel
    else ZapChannel;

pub fn main() !void {
    if (use_event_loop) {
        try sieve();
    } else {
        const result = try zap.Task.run(.{}, sieve, .{N});
        try result;
    }
}

// The prime sieve: Daisy-chain Filter processes.
fn sieve(n: usize) !void {
    // This techinque requires O(N) memory. It's not obvious from the Go
    // code, but Zig has no hidden allocations.
    // An arena allocator lets us free all the memory at once.
    // In this case we let the operating system do the freeing, since
    // that is most efficient.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = &arena.allocator;

    // Create a new channel.
    var ch = try allocator.create(Channel(u32));
    ch.init(&[0]u32{}); // Unbuffered channel.

    // Start the generate async function.
    // In this case we let it run forever, not bothering to `await`.
    _ = async generate(ch);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const prime = ch.get();
        //std.debug.warn("{}\n", .{ prime });
        const ch1 = try allocator.create(Channel(u32));
        ch1.init(&[0]u32{});
        (try allocator.create(@Frame(filter))).* = async filter(ch, ch1, prime);
        ch = ch1;
    }
}

// Send the sequence 2, 3, 4, ... to channel 'ch'.
fn generate(ch: *Channel(u32)) void {
    var i: u32 = 2;
    while (true) : (i += 1) {
        ch.put(i);
    }
}

// Copy the values from channel 'in' to channel 'out',
// removing those divisible by 'prime'.
fn filter(in: *Channel(u32), out: *Channel(u32), prime: u32) void {
    while (true) {
        const i = in.get();
        if (i % prime != 0) {
            out.put(i);
        }
    }
}

fn ZapChannel(comptime T: type) type {
    return struct {
        lock: std.Mutex,
        buffer: []T,
        head: usize,
        tail: usize,
        getter: ?*Waiter,
        setter: ?*Waiter,

        const Self = @This();
        const Waiter = struct {
            task: zap.Task,
            next: ?*Waiter,
            last: *Waiter,
            item: ?T,
        };

        pub fn init(self: *Self, buffer: []T) void {
            self.* = Self{
                .lock = std.Mutex.init(),
                .buffer = buffer,
                .head = 0,
                .tail = 0,
                .getter = null,
                .setter = null,
            };
        }

        pub fn put(self: *Self, item: T) void {
            const held = self.lock.acquire();

            // Pop a waiting getter and hand-off the item directly.
            if (self.getter) |get_waiter| {
                const getter = get_waiter;
                self.getter = getter.next;
                held.release();
                getter.item = item;
                const context = zap.Task.getContext() orelse unreachable;
                context.schedule(getter.task.getRunnable());
                return;
            }

            // Try to add the item into the buffer
            if (self.tail -% self.head < self.buffer.len) {
                self.buffer[self.tail] = item;
                self.tail +%= 1;
                held.release();
                return;
            }

            // Enqueue a waiter with the item into the setter queue
            var waiter: Waiter = undefined;
            waiter.item = item;
            waiter.next = null;
            waiter.last = &waiter;
            if (self.setter) |head| {
                head.last.next = &waiter;
                head.last = &waiter;
            } else {
                self.setter = &waiter;
            }

            // Wait for our waiter to have its item consumed
            suspend {
                const context = zap.Task.getContext() orelse unreachable;
                waiter.task = context.initTask(@frame(), .Normal);
                held.release();
            }
            std.debug.assert(waiter.item == null);
        }

        pub fn get(self: *Self) T {
            const held = self.lock.acquire();

            // Check for any waiting settters and directly consume their item.
            if (self.setter) |set_waiter| {
                const setter = set_waiter;
                self.setter = setter.next;
                held.release();
                const item = setter.item;
                setter.item = null;
                const context = zap.Task.getContext() orelse unreachable;
                context.schedule(setter.task.getRunnable());
                return item.?;
            }

            // Try to pop an item from the buffer
            if (self.tail -% self.head != 0) {
                const item = self.buffer[self.head];
                self.head +%= 1;
                held.release();
                return item;
            }

            // Enqueue a waiter with a location for an item into the getter queue
            var waiter: Waiter = undefined;
            waiter.item = null;
            waiter.next = null;
            waiter.last = &waiter;
            if (self.getter) |head| {
                head.last.next = &waiter;
                head.last = &waiter;
            } else {
                self.getter = &waiter;
            }

            // Wait for our waiter to have its item filled in by a setter.
            suspend {
                const context = zap.Task.getContext() orelse unreachable;
                waiter.task = context.initTask(@frame(), .Normal);
                held.release();
            }
            return waiter.item.?;
        }
    };
}