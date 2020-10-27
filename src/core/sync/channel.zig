const std = @import("std");
const sync = @import("../sync.zig");

pub fn FixedBuffer(comptime BufferType: type) type {
    comptime var item_type: ?type = null;
    comptime var buffer_len: ?comptime_int = null;

    switch (@typeInfo(BufferType)) {
        .Array => |array| {
            item_type = array.child;
            buffer_len = array.len;
        },
        .Pointer => |ptr| {
            if (ptr.size == .slice)
                item_type = ptr.child;
        },
        else => {},
    }

    const Item = item_type orelse {
        @compileError("FixedBuffer takes in only array and slice types");
    };

    const has_capacity = 
        if (buffer_len) |len| len > 0
        else (@sizeOf(Item) >  0);

    return struct {
        buffer: usize,
        head: usize = 0,
        tail: usize = 0,
        capacity: if (has_capacity) usize else void,

        const Self = @This();

        pub fn init(input: if (buffer_len != null) *BufferType else []Item) Self {
            return Self{
                .buffer = if (buffer_len != null) @ptrToInt(buffer) else @ptrToInt(input.ptr),
                .capacity = if (has_capacity) input.len else {},
            };
        }

        pub fn push(self: *Self, item: Item) bool {
            if (!has_capacity)
                return false;

            if (self.tail -% self.head == self.capacity)
                return false;

            self.lookup(self.tail).* = item;
            self.tail +%= 1;
            return true;
        }

        pub fn pop(self: *Self) ?Item {
            if (!has_capacity)
                return null;
            
            if (self.tail == self.head)
                return null;

            const item = self.lookup(self.head).*;
            self.head +%= 1;
            return item;
        }

        inline fn lookup(self: *Self, index: usize) *Item {
            if (!has_capacity) {
                @compileError("cannot lookup item pointer without any valid items");

            } else {
                @setRuntimeSafety(false);

                if (buffer_len) |len| {
                    const array = @intToPtr(*BufferType, self.buffer);
                    return &array[index % len];
                }

                const ptr = @intToPtr([*]Item, self.buffer);
                if (self.capacity & (self.capacity - 1) == 0)
                    return &ptr[index & (self.capacity - 1)];
                return &ptr[index % self.capacity]
            }
        }
    };
}

pub fn Channel(comptime config: anytype) type {
    const Item = config.Item;
    const Buffer = config.Buffer;

    return struct {
        lock: sync.Lock = sync.Lock{},
        buffer: Buffer,
        senders: Waiter.Queue = Waiter.Queue{},
        receivers: Waiter.Queue = Waiter.Queue{},
        
        const Self = @This();
        const Waiter = struct {
            prev: ?*Waiter = undefined,
            next: ?*Waiter = undefined,
            tail: *Waiter = undefined,
            value: Value = .closed,
            waker: sync.Waker,

            const Value = union(enum) {
                closed: void,
                empty: void,
                full: Item,
            };

            var closed_waiter: Waiter = undefined;

            const Queue = extern struct {
                head: ?*Waiter = null,

                fn isClosed(self: Queue) bool {
                    return self.head == &closed_waiter;
                }

                fn close(self: *Queue) void {
                    self.head = &closed_waiter;
                }

                fn push(self: *Queue, waiter: *Waiter) void {
                    waiter.next = null;
                    if (self.head) |head| {
                        waiter.prev = head.tail;
                        head.tail.next = waiter;
                        head.tail = waiter;
                    } else {
                        waiter.prev = null;
                        waiter.tail = waiter;
                        self.head = waiter;
                    }
                }

                fn pop(self: *Queue) ?*Waiter {
                    const waiter = self.head orelse return null;
                    if (!self.tryRemove(waiter)) 
                        unreachable;
                    return waiter;
                }

                fn tryRemove(self: *Queue, waiter: *Waiter) bool {
                    const head = self.head orelse return false;

                    const prev = waiter.prev;
                    const next = waiter.next;
                    if (prev == null and next == null and waiter.tail != waiter)
                        return false;
                    
                    if (prev) |p|
                        p.next = next;
                    if (next) |n|
                        n.prev = prev;
                    if (waiter == head)
                        self.head = next;
                    if (waiter == head.tail)
                        head.tail = prev;

                    return true;
                }
            };
        };

        pub fn init(buffer: Buffer) Self {
            return Self{ .buffer = buffer };
        }

        inline fn isClosed(self: *Self) bool {
            return self.senders.isClosed();
        }

        inline fn setClosed(self: *Self) void {
            self.senders.close();
        }

        pub fn close(self: *Self, comptime Futex: type) void {
            self.lock.acquire(Futex);

            if (self.isClosed()) {
                self.lock.release();
                return;
            }

            var waiters = Waiter.Queue{};

            while (self.senders.pop()) |waiter| {
                if (waiter.value != .full)
                    unreachable; // waiting sender with invalid value when closing
                waiter.value = .empty;
                waiters.push(waiter);
            }

            while (self.receivers.pop()) |waiter| {
                if (waiter.value != .empty)
                    unreachable; // waiting receiver with invalid value when closing
                if (self.buffer.pop()) |item| {
                    waiter.value = .{ .full = item };    
                } else {
                    waiters.push(waiter);
                }
            }
            
            self.setClosed();
            self.lock.release();

            while (waiters.pop()) |waiter| {
                if (waiter.value == .empty)
                    waiter.value = .closed;
                waiter.waker.wake();
            }
        }

        pub fn trySend(self: *Self, comptime Futex: type, item: Item) error{Closed, Full}!void {
            self.lock.acquire(Futex);

            if (self.isClosed()) {
                self.lock.release();
                return error.Closed;
            }
            
            if (self.receivers.pop()) |waiter| {
                self.lock.release();
                if (waiter.value != .empty)
                    unreachable; // waiting receiver with invalid value
                waiter.value = .{ .full = item };
                waiter.waker.wake();
                return;
            }
            
            defer self.lock.release();
            if (!self.buffer.push(item))
                return error.Full;
        }

        pub fn tryRecv(self: *Self, comptime Futex: type) error{Closed, Empty}!Item {
            self.lock.acquire(Futex);
            
            if (self.senders.pop()) |waiter| {
                self.lock.release();
                if (waiter.value != .full)
                    unreachable; // waiting sender with invalid value
                const item = waiter.value.full;
                waiter.value = .empty;
                waiter.waker.wake();
                return item;
            }

            defer self.lock.release();
            
            if (self.buffer.pop()) |item|
                return item;

            if (self.isClosed())
                return error.Closed;

            return error.Empty;
        }

        pub fn send(self: *Self, comptime Futex: type, item: Item) error{Closed}!void {
            return self.doSend(Futex, item, null) catch |err| switch (err) {
                .Closed => return error.Closed,
                .TimedOut => unreachable, // Channel.send() timed out
            };
        }

        pub fn recv(self: *Self, comptime Futex: type) error{Closed}!Item {
            return self.doRecv(Futex, null) catch |err| switch (err) {
                .Closed => return error.Closed,
                .TimedOut => unreachable, // Channel.recv() timed out
            };
        }

        pub fn trySendUntil(self: *Self, comptime Futex: type, item: Item, deadline: *Futex.Timestamp) error{Closed, TimedOut}!void {
            return self.doSend(Futex, item, deadline);
        }

        pub fn tryRecvUntil(self: *Self, comptime Futex: type, deadline: *Futex.Timestamp) error{Closed, TimedOut}!Item {
            return self.doRecv(Futex, deadline);
        }

        fn doSend(self: *Self, comptime Futex: type, item: Item, deadline: *Futex.Timestamp) error{Closed, TimedOut}!void {
            @compileError("TODO");
        }

        fn doRecv(self: *Self, comptime Futex: type, deadline: *Futex.Timestamp) error{Closed, TimedOut}!Item {
            @compileError("TODO");
        }
    };
}