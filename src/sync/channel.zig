const zap = @import("../zap.zig");
const atomic = zap.sync.atomic;
const nanotime = zap.runtime.nanotime;
const Lock = zap.runtime.Lock;
const Allocator = zap.runtime.Allocator;

pub fn Channel(comptime T: type) type {
    return struct {
        lock: Lock = Lock{},
        buffer: [*]T = undefined,
        state: usize,
        head: usize = 0,
        tail: usize = 0,
        readers: ?*Waiter = null,
        writers: ?*Waiter = null,
        allocator: ?*Allocator = null,

        const Self = @This();
        const State = struct {
            capacity: usize = 0,
            is_empty: bool = true,
            is_closed: bool = false,
            has_buffer: bool = false,

            fn boundCapacity(capacity: usize) usize {
                const max_capacity = ~@as(usize, 0) >> 3;
                if (capacity < max_capacity)
                    return capacity;
                return max_capacity;
            }

            fn growCapacity(capacity: usize) usize {

            }

            fn pack(self: State) usize {
                return (
                    (boundCapacity(self.capacity) << 3) |
                    (@as(usize, @boolToInt(self.is_empty)) << 2) |
                    (@as(usize, @boolToInt(self.is_closed)) << 1) |
                    (@as(usize, @boolToInt(self.has_buffer)) << 0)
                );
            }

            fn unpack(value: usize) State {
                return State{
                    .capacity = value >> 3,
                    .is_empty = value & (1 << 2) != 0,
                    .is_closed = value & (1 << 1) != 0,
                    .has_buffer = value & (1 << 0) != 0,
                };
            }
        };

        const Waiter = struct {
            prev: ?*Waiter,
            next: ?*Waiter,
            tail: ?*Waiter,
            item: T,
            is_closed: bool,
            wakeFn: fn(*Waiter) void,
        };

        pub fn buffered(buffer: []T) Self {
            return Self{
                .buffer = buffer.ptr,
                .state = (State{
                    .capacity = buffer.len,
                    .has_buffer = true,
                }).pack(),
            };
        }

        pub fn unbounded(allocator: *Allocator) Self {
            return Self.withCapacity(allocator, 8);
        }

        pub fn withCapacity(allocator: *Allocator, capacity: usize) Self {
            return Self{
                .allocator = allocator,
                .state = (State{
                    .capacity = capacity,
                    .has_buffer = false,
                }).pack(),
            };
        }

        pub fn push(self: *Self, comptime Event: type, item: T) error{Closed, OutOfMemory}!void {
            return self.doPush(Event, null, item) catch |err| switch (err) {
                error.TimedOut => unreachable,
                else => |e| return e,
            };
        }

        pub fn tryPush(self: *Self, item: T) error{Closed, Full, OutOfMemory}!void {
            var locked: bool = undefined;
            const result = self.doTryPush(item, &locked);
            if (locked) self.lock.release();
            return result;
        }

        pub fn tryPushFor(self: *Self, comptime Event: type, duration: u64, item: T) error{Closed, TimedOut, OutOfMemory}!void {
            return self.tryPushUntil(Event, nanotime() + duration, item);
        }

        pub fn tryPushUntil(self: *Self, comptime Event: type, deadline: u64, item: T) error{Closed, TimedOut, OutOfMemory}!void {
            return self.doPush(Event, deadline, item);
        }

        pub fn pop(self: *Self, comptime Event: type) error{Closed}!T {
            return self.doPop(Event, null) catch |err| switch (err) {
                error.TimedOut => unreachable,
                else => |e| return e,
            };
        }

        pub fn tryPop(self: *Self) error{Closed, Empty}!T {
            var locked: bool = undefined;
            const result = self.doTryPop(&locked);
            if (locked) self.lock.release();
            return result;
        }

        pub fn tryPopFor(self: *Self, comptime Event: type, duration: u64) error{Closed, TimedOut}!T {
            return self.tryPopUntil(nanotime() + duration);
        }

        pub fn tryPopUntil(self: *Self, comptime Event: type, duration: u64) error{Closed, TimedOut}!T {
            return self.doPop(Event, duration);
        }

        pub fn deinit(self: *Self) void {
            defer self.* = undefined;
            
            self.lock.acquire();
            
            var state = State.unpack(self.state);
            defer self.doClose(&state);

            if (@sizeOf(T) > 0 and state.has_buffer and state.capacity > 1) {
                if (self.allocator) |allocator| {
                    allocator.free(self.buffer[0..state.capacity]);
                    state.has_buffer = false;
                }
            }
        }

        pub fn close(self: *Self) void {
            if (blk: {
                const state = atomic.load(&self.state, .relaxed);
                break :blk State.unpack(state).is_closed;
            }) {
                return;
            }

            self.lock.acquire();

            var state = State.unpack(self.state);
            if (state.is_closed) {
                self.lock.release();
            } else {
                self.doClose(&state);
            }
        }

        fn doClose(self: *Self, state: *State) void {
            var waiters: ?*Waiter = self.readers;
            self.readers = null;

            const target = if (waiters) |head| @ptrCast(*?*Waiter, &head.tail) else &waiters;
            target.* = self.writers;
            self.writers = null;

            state.is_closed = true;
            atomic.store(&self.state, state.pack(), .relaxed);
            self.lock.release();

            while (waiters) |pending_waiter| {
                const waiter = pending_waiter;
                waiters = waiter.next;
                waiter.is_closed = true;
                (waiter.wakeFn)(waiter);
            }
        }

        fn pushItem(self: *Self, state: *State, item: T) void {
            if (@sizeOf(T) > 0)
                self.buffer[self.tail] = item;

            self.tail += 1;
            if (self.tail >= state.capacity)
                self.tail = 0;

            if (state.is_empty) {
                state.is_empty = false;
                atomic.store(&self.state, state.pack(), .relaxed);
            }
        }

        fn popItem(self: *Self, state: *State) ?T {
            if (state.is_empty)
                return null;

            var item: T = undefined;
            if (@sizeOf(T) > 0)
                item = self.buffer[self.head];

            self.head += 1;
            if (self.head >= state.capacity)
                self.head = 0;

            if (self.head == self.tail) {
                state.is_empty = true;
                atomic.store(&self.state, state.pack(), .relaxed);
            }

            return item;
        }

        fn doTryPush(self: *Self, item: T, locked: *bool) error{Closed, Full, OutOfMemory}!void {
            if (blk: {
                const state = atomic.load(&self.state, .relaxed);
                break :blk State.unpack(state).is_closed;
            }) {
                locked.* = false;
                return error.Closed;
            }

            self.lock.acquire();
            locked.* = true;

            var state = CapState.unpack(self.state);
            if (state.is_closed)
                return error.Closed;

            if (self.readers) |reader| {
                const waiter = reader;
                self.readers = waiter.next;
                if (self.readers) |head|
                    head.tail = waiter.tail;

                self.lock.release();
                locked.* = false;
                waiter.item = item;
                return;
            }

            if (state.capacity == 0)
                return error.Full;

            if (!state.has_buffer) {
                const allocator = self.allocator orelse return error.Full;
                self.buffer = allocator.alloc(T, state.capacity) catch return error.OutOfMemory;
                state.has_buffer = true;
                atomic.store(&self.state, state.pack(), .relaxed);
            }

            if (!state.is_empty and self.head == self.tail) {
                const allocator = self.allocator orelse return error.Full;
                const new_capacity = State.growCapacity(state.capacity);
                if (new_capacity == state.capacity)
                    return error.Full;

                const new_buffer = allocator.alloc(T, new_capacity) catch return error.OutOfMemory;
                var new_tail: usize = 0;
                while (self.popItem(&state)) |item| {
                    if (@sizeOf(T) > 0)
                        new_buffer[new_tail] = item;
                    new_tail += 1;
                }

                allocator.free(self.buffer[0..state.capacity]);
                self.buffer = new_buffer;

                self.head = 0;
                self.tail = new_tail;
                state.capacity = new_capacity;
                atomic.store(&self.state, state.pack(), .relaxed);
            }

            self.pushItem(&state, item);
        }

        fn doTryPop(self: *Self, locked: *bool) error{Closed, Empty}!T {

        }

        fn doPush(self: *Self, comptime Event: type, deadline: ?u64, item: T) error{Closed, TimedOut, OutOfMemory}!void {
            var locked: bool = undefined;
            if (self.doTryPush(item)) |_| {
                return;
            } else |err| {
                switch (err) {
                    error.Full => {},
                    error.Closed, error.OutOfMemory => {
                        if (locked) self.lock.release();
                        return err;
                    },
                }
            }

            _ = try self.wait(&self.writers, Event, deadline, item);
        }

        fn doPop(self: *Self, comptime Event: type, deadline: ?u64) error{Closed, TimedOut}!T {

        }

        fn wait(self: *Self, queue: *?*Waiter, comptime Event: type, deadline: ?u64, item: T) error{Closed, TimedOut}!T {
            @setCold(true);

            const EventWaiter = struct {
                waiter: Waiter,
                event: Event,

                fn wake(waiter: *Waiter) void {
                    const self = @fieldParentPtr(@This(), "waiter", waiter);
                    self.event.notify();
                }
            };

            var event_waiter: EventWaiter = undefined;
            const waiter = &event_waiter.waiter;
            const event = &event_waiter.event;

            waiter.tail = waiter;
            waiter.next = null;
            waiter.item = item;
            waiter.is_closed = false;

            if (queue.*) |head| {
                const tail = head.tail orelse unreachable;
                tail.next = waiter;
                waiter.prev = tail;
                head.tail = waiter;
            } else {
                queue.* = waiter;
                waiter.prev = null;
            }
            
            event.* = Event{};
            var notified = event.wait(deadline, struct {
                channel: *Self,
                
                pub fn wait(this: @This()) bool {
                    this.channel.lock.release();
                    return true;
                }
            } {
                .channel = self,
            });

            blk: {
                if (notified)
                    break :blk;

                self.lock.acquire();
                if (waiter.tail == null) {
                    self.lock.release();
                    break :blk;
                }

                @compileError("TODO: remove")
            }

            if (waiter.is_closed)
                return error.Closed;
            return waiter.item;
        }
    };
}