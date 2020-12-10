const zap = @import("../zap.zig");
const atomic = zap.sync.atomic;
const nanotime = zap.runtime.Clock.nanotime;
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

            const max_capacity = ~@as(usize, 0) >> 3;

            fn boundCapacity(capacity: usize) usize {
                if (capacity < max_capacity)
                    return capacity;
                return max_capacity;
            }

            fn growCapacity(capacity: usize) usize {
                const new_capacity = boundCapacity(capacity << 1);
                if (new_capacity > capacity)
                    return new_capacity;
                return max_capacity;
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
            return self.doTryPush(item) catch |err| switch (err) {
                error.Full => {
                    self.lock.release();
                    return error.Full;
                },
                else => |e| return e,
            };
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
            return self.doTryPop() catch |err| switch (err) {
                error.Empty => {
                    self.lock.release();
                    return error.Empty;
                },
                else => |e| return e,
            };
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
            self.doClose(&state, true);
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
                self.doClose(&state, false);
            }
        }

        fn doClose(self: *Self, state: *State, free_buffer: bool) void {
            var waiters: ?*Waiter = self.readers;
            self.readers = null;

            const target = if (waiters) |head| &head.tail else &waiters;
            target.* = self.writers;
            self.writers = null;

            if (free_buffer and @sizeOf(T) > 0 and state.has_buffer and state.capacity > 1) {
                if (self.allocator) |allocator| {
                    allocator.free(self.buffer[0..state.capacity]);
                    state.has_buffer = false;
                }
            }

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
            if (state.is_empty or state.capacity == 0 or !state.has_buffer)
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

        fn doTryPush(self: *Self, item: T) error{Closed, Full, OutOfMemory}!void {
            if (blk: {
                const state = atomic.load(&self.state, .relaxed);
                break :blk State.unpack(state).is_closed;
            }) {
                return error.Closed;
            }

            self.lock.acquire();

            var state = CapState.unpack(self.state);
            if (state.is_closed) {
                self.lock.release();
                return error.Closed;
            }

            if (self.readers) |reader| {
                const waiter = reader;
                _ = self.tryRemoveQueue(&self.readers, waiter);
                self.lock.release();

                waiter.item = item;
                (waiter.wakeFn)(waiter);
                return;
            }

            if (state.capacity == 0)
                return error.Full;

            if (!state.has_buffer) {
                const allocator = self.allocator orelse unreachable;
                self.buffer = allocator.alloc(T, state.capacity) catch {
                    self.lock.release();
                    return error.OutOfMemory;
                };
                state.has_buffer = true;
                atomic.store(&self.state, state.pack(), .relaxed);
            }

            if (!state.is_empty and self.head == self.tail) {
                const allocator = self.allocator orelse return error.Full;
                const new_capacity = State.growCapacity(state.capacity);
                if (new_capacity == state.capacity)
                    return error.Full;

                var new_buffer: [*]T = undefined;
                if (@sizeOf(T) > 0) {
                    new_buffer = allocator.alloc(T, new_capacity) catch {
                        self.lock.release();
                        return error.OutOfMemory;
                    };
                }

                var new_tail: usize = 0;
                while (self.popItem(&state)) |item| {
                    if (@sizeOf(T) > 0)
                        new_buffer[new_tail] = item;
                    new_tail += 1;
                }
                
                if (@sizeOf(T) > 0)
                    allocator.free(self.buffer[0..state.capacity]);

                self.buffer = new_buffer;
                self.head = 0;
                self.tail = new_tail;
                state.capacity = new_capacity;
                atomic.store(&self.state, state.pack(), .relaxed);
            }

            return self.pushItem(&state, item);
        }

        fn tryRemoveQueue(self: *Self, queue: *?*Waiter, waiter: *Waiter) bool {
            const head = queue.* orelse return false;
            if (waiter.tail == null)
                return false;

            if (waiter.prev) |prev|
                prev.next = waiter.next;
            if (waiter.next) |next|
                next.prev = waiter.prev;

            if (waiter == head) {
                queue.* = waiter.next;
                if (queue.*) |new_head|
                    new_head.tail = waiter.tail;
            } else if (waiter == head.tail) {
                head.tail = waiter.prev;
            }

            waiter.tail = null;
            return true;
        }

        fn doTryPop(self: *Self) error{Closed, Empty}!T {
            self.lock.acquire();

            var state = State.unpack(self.state);
            if (self.popItem(&state)) |item| {
                self.lock.release();
                return item;
            }

            if (self.writers) |writer| {
                const waiter = writer;
                _ = self.tryRemoveQueue(&self.writers, waiter);
                self.lock.release();

                const item = waiter.item;
                (waiter.wakeFn)(waiter);
                return item;
            }

            if (state.is_closed) {
                self.lock.release();
                return error.Closed;
            }

            return error.Empty;
        }

        fn doPush(self: *Self, comptime Event: type, deadline: ?u64, item: T) error{Closed, TimedOut, OutOfMemory}!void {
            return self.doTryPush(item) catch |err| switch (err) {
                error.Full => {
                    _ = try self.wait(&self.writers, Event, deadline, item);
                    return;
                },
                else => |e| return e,
            };
        }

        fn doPop(self: *Self, comptime Event: type, deadline: ?u64) error{Closed, TimedOut}!T {
            return self.doTryPop() catch |err| switch (err) {
                error.Empty => return self.wait(&self.readers, Event, deadline, undefined),
                else => |e| return e,
            };
        }

        fn wait(self: *Self, queue: *?*Waiter, comptime Event: type, deadline: ?u64, item: T) error{Closed, TimedOut}!T {
            @setCold(true);

            const EventWaiter = struct {
                waiter: Waiter,
                event: Event,
                channel: *Self,

                fn wake(waiter: *Waiter) void {
                    const self = @fieldParentPtr(@This(), "waiter", waiter);
                    self.event.notify();
                }

                fn wait(self: *@This()) bool {
                    self.channel.lock.release();
                    return true;
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
            event_waiter.channel = self;

            var notified = event.wait(deadline, &event_waiter);
            if (!notified) {
                self.lock.acquire();
                
                if (self.tryRemoveQueue(queue, waiter)) {
                    self.lock.release();
                    return error.TimedOut;
                }

                notified = event.wait(null, &event_waiter);
                if (!notified)
                    unreachable;
            }

            if (waiter.is_closed)
                return error.Closed;
            return waiter.item;
        }
    };
}