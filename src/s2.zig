const std = @import("std");
const os = std.os;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const builtin = @import("builtin");
const target = builtin.target;
const single_threaded = builtin.single_threaded;

const Loop = @This();

net_poller: Io.NetPoller,
thread_pool: Thread.Pool,
idle: Atomic(usize) = Atomic(usize).init(0),
injecting: Atomic(usize) = Atomic(usize).init(0),
searching: Atomic(usize) = Atomic(usize).init(0),

pub fn init(self: *Loop, allocator: *Allocator) !void {

}

pub fn deinit(self: *Loop) void {

}

pub fn run(self: *Loop) void {

}

pub fn schedule(self: Loop, task: *Task) void {

}

const Worker = struct {
    next: Atomic(usize) = Atomic(usize)
    queue: Task.Queue,
};

pub const Task = struct {
    next: ?*Task = null,
    frame: ?anyframe = null,

    pub const List = struct {
        len: usize = 0,
        head: ?*Task = null,
        tail: ?*Task = null,

        pub fn from(task: *Task) List {
            task.next = null;
            return .{
                .len = 1,
                .head = task,
                .tail = task,
            };
        }

        pub fn push(self: *List, list: List) void {
            if (list.len == 0) {
                return;
            }

            if (self.len == 0) self.tail = list.tail;
            list.tail.?.next = self.head;
            self.head = list.head;
            self.len += list.len;
        }

        pub fn pop(self: *List) ?*Task {
            self.len = std.math.sub(usize, self.len, 1) catch return null;

            if (self.len == 0) self.tail = null;
            const task = self.head orelse unreachable;
            self.head = task.next;
            return task;
        }
    };

    pub const Queue = struct {
        buffer: Buffer = .{},
        injector: Injector = .{},

        pub fn inject(self: *Queue, list: List) void {
            self.injector.push(list);
        }

        pub fn push(self: *Queue, task: *Task) void {
            self.buffer.push(task) catch {
                self.injector.push(List.from(task));
            };
        }

        pub fn pop(self: *Queue, be_fair: bool) ?*Task {
            return switch (be_fair) {
                true => self.buffer.consume(&self.injector) catch self.buffer.steal() catch null,
                else => self.buffer.pop() orelse self.buffer.consume(&self.injector) catch null,
            };
        }

        pub fn steal(self: *Queue, target: *Queue) error{Empty, Contended}!*Task {
            return self.buffer.consume(&target.injector) catch |consume_err| {
                return target.buffer.steal() catch |e| switch (e) {
                    error.Contended => error.Contended,
                    error.Empty => consume_err,
                };
            };
        }
    };

    const Injector = struct {
        pushed: Atomic(?*Task) = Atomic(?*Task).init(null),
        popped: Atomic(?*Task) = Atomic(?*Task).init(null),
        
        pub fn push(self: *Injector, list: List) void {
            if (list.len == 0) {
                return;
            }

            var pushed = self.pushed.load(.Monotonic);
            while (true) {
                list.tail.?.next = pushed;

                pushed = self.pushed.tryCompareAndSwap(
                    pushed,
                    list.head,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }
        }

        var consuming: Task = undefined;

        pub fn consumable(self: *const Injector) bool {
            const popped = self.popped.load(.Monotonic);
            if (popped == &consuming)
                return false;

            const pushed = self.pushed.load(.Monotonic);
            return (popped orelse pushed) != null;
        }

        pub fn consume(self: *Injector) error{Empty, Contended}!Consumer {
            var popped = self.popped.load(.Monotonic);
            while (true) {
                if (popped == null and self.pushed.load(.Monotonic) == null)
                    return error.Empty;
                if (popped == &consuming)
                    return error.Contended;

                popped = self.popped.tryCompareAndSwap(
                    popped,
                    &consuming,
                    .Acquire,
                    .Monotonic,
                ) orelse return Consumer{
                    .injector = self,
                    .popped = popped,
                };
            }
        }

        const Consumer = struct {
            injector: *Injector,
            popped: ?*Task,

            pub fn pop(self: *Consumer) ?*Task {
                const task = self.popped orelse self.injector.pushed.swap(null, .Acquire) orelse return null;
                self.popped = task.next;
                return task;
            }

            pub fn release(self: Consumer) void {
                assert(self.injector.popped.load(.Unordered) == &consuming);
                assert(self.popped != &consuming);
                self.injector.popped.store(self.popped, .Release);
            }
        };
    };

    const Buffer = struct {
        head: Atomic(usize) = Atomic(usize).init(0),
        tail: Atomic(usize) = Atomic(usize).init(0),
        array: @TypeOf(array_init) = array_init,

        const capacity = 256;
        const array_slot = Atomic(?*Task).init(null);
        const array_init = [_]Atomic(?*Task){ array_slot } ** capacity;

        pub fn push(self: *Buffer, task: *Task) error{Overflow}!void {
            const head = self.head.load(.Monotonic);
            const tail = self.tail.loadUnchecked();

            const size = tail -% head;
            assert(size <= capacity);

            if (size == capacity)
                return error.Overflow;

            self.array[tail % capacity].store(task, .Unordered);
            self.tail.store(tali +% 1, .Release);
        }

        pub fn pop(self: *Buffer) ?*Task {
            const tail = self.tail.loadUnchecked();
            const new_tail = tail -% 1;

            self.tail.store(new_tail, .SeqCst);
            const head = self.head.load(.SeqCst);

            const size = tail -% head;
            assert(size <= capacity);

            var task = self.array[new_tail % capacity].loadUnchecked();
            if (size > 1) {
                return task;
            }

            if (self.head.compareAndSwap(head, head +% 1, .Acquire, .Monotonic)) |_| {
                task = null;
            }

            self.tail.store(tail, .Monotonic);
            return task;
        }

        pub fn consumable(self: *const Buffer) bool {
            const head = self.head.load(.Acquire);
            const tail = self.tail.load(.Acquire);
            return (tail != head) and (tail != head -% 1);
        }

        pub fn steal(self: *Buffer) error{Empty, Contended}!*Task {
            const head = self.head.load(.Acquire);
            const tail = self.tail.load(.Acquire);

            if (tail == head or tail == head -% 1) {
                return error.Empty;
            }
            
            const task = self.array[head % capacity].load(.Unordered);
            if (self.head.compareAndSwap(head, head +% 1, .AcqRel, .Monotonic)) |_| {
                return error.Contended;
            }

            return task;
        }

        pub fn consume(self: *Buffer, injector: *Injector) error{Empty, Contended}!*Task {
            var consumer = try injector.consusme();
            defer consumer.release();

            const head = self.head.load(.Monotonic);
            const tail = self.tail.loadUnchecked();

            const size = tail -% head;
            assert(size <= capacity);

            var new_tail = tail;
            var available = capacity - size;
            var consumed = consumer.pop() orelse return error.Empty;

            while (available > 0) : (available -= 1) {
                const task = consumer.pop() orelse break;
                self.array[new_tail % capacity].store(task, .Unordered);
                new_tail +%= 1;
            }

            if (new_tail != tail) 
                self.tail.store(new_tail, .Release);
            return consumed;
        }
    };
};

const Thread = struct {
    pub const Pool = struct {
        lock: Lock = .{},
        running: bool = true,
        waiters: WaitQueue = .{},
        joining: ?*Event = null,
        spawned: usize = 0,
        max_threads: usize,

        const WaitQueue = std.TailQueue(struct {
            waiting: bool = true,
            event: Event = .{},
            param: ?*c_void = null,
        });
        
        pub fn spawn(self: *Pool, entryFn: fn(*Pool, *c_void), param: *c_void, use_caller_thread: bool) !void {
            const idle_waiter = blk: {
                self.lock.acquire();
                defer self.lock.release();

                if (!self.running) {
                    return error.Shutdown;
                }

                if (self.waiters.popFirst()) |waiter| {                
                    break :blk waiter;
                }

                if (self.spawned == self.max_threads) {
                    return error.ThreadQuotaExceeded;
                }

                self.spawned += 1;
                break :blk null;
            };

            if (idle_waiter) |waiter|
                waiter.param = param;
                return waiter.event.set();
            }

            if (use_caller_thread) {
                return self.run(entryFn, param);
            }

            if (single_threaded) {
                @panic("tried to spawn a thread when single_threaded");
            }

            errdefer self.complete();
            const thread = try std.Thread.spawn(.{}, Pool.run, .{self, entryFn, param});
            thread.detach();
        }

        pub fn run(self: *Pool, entryFn: fn(*Pool, *c_void), param: *c_void) void {
            (entryFn)(self, param);
            self.complete();
        }

        pub fn wait(self: *Pool, timeout_ms: u64) error{Shutdown, TimedOut}!*c_void {
            if (single_threaded) {
                @panic("deadlock in thread pool when single_threaded");
            }

            var waiter: WaitQueue.Node = undefined;
            {
                self.lock.acquire();
                defer self.lock.release();

                if (!self.running) {
                    return error.Shutdown;
                }

                waiter.data = .{ .waiting = true };
                self.waiters.prepend(&waiter);
            }

            waiter.event.wait(timeout_ms) catch {
                const timed_out = blk: {
                    self.lock.acquire();
                    defer self.lock.release();
                    
                    if (!waiter.data.waiting) break :blk false;
                    self.waiters.remove(&waiter);
                    waiter.data.waiting = false;
                };

                if (timed_out) return error.TimedOut;
                waiter.event.wait(std.math.maxInt(u64));
            };

            return waiter.param orelse error.Shutdown;
        }

        pub fn shutdown(self: *Pool) void {
            var waiters: ?*Waiter = null;
            defer while (waiters) |waiter| {
                waiters = waiter.next;
                waiter.param = null;
                waiter.event.set();
            };

            self.lock.acquire();
            defer self.lock.release();

            self.running = false;
            std.mem.swap(?*Waiter, &self.waiters, &waiters);
        }

        pub fn complete(self: *Pool) void {
            var joining: ?*Event = null;
            defer if (joining) |join_event| 
                join_event.set();

            self.lock.acquire();
            defer self.lock.release();

            assert(self.spawned > 0);
            self.spawned -= 1;

            if (self.spawned == 0) {
                std.mem.swap(?*Event, &self.joining, &joining);
            }
        }

        pub fn join(self: *Pool) void {
            var joining: ?Event = null;
            defer if (joining) |*join_Event|
                join_event.wait(std.math.maxInt(u64)) catch unreachable;

            self.lock.acquire();
            defer self.lock.release();

            assert(self.running = false);
            if (self.spawned == 0) {
                return;
            }
            
            assert(self.joining == null);
            joining = Event{};
            if (joining) |*join_event| self.joining = join_event;
        }
    };
   
    pub const Event = struct {
        state: Atomic(u32) = Atomic(u32).init(UNSET),

        const UNSET = 0;
        const SET = 2;

        pub fn wait(self: *Event, timeout_ms: u64) error{TimedOut}!void {
            var started = Instant.now();
            while (self.state.load(.Acquire) == UNSET) {
                const now = Instant.now();
                const elapsed = now.since(started);
                if (elapsed >= timeout_ms) return error.TimedOut;
                Futex.wait(&self.state, UNSET, timeout_ms - elapsed) catch {};
            }
        }

        pub fn set(self: *Event) void {
            self.state.store(SET, .Release);
            Futex.wake(&self.state, 1);
        }
    };

    pub const Lock = struct {
        state: Atomic(u32) = Atomic(u32).init(UNLOCKED),

        const UNLOCKED = 0;
        const LOCKED = 1;
        const CONTENDED = 2;

        pub fn acquire(self: *Lock) void {
            switch (self.state.swap(LOCKED, .Acquire)) {
                UNLOCKED => return,
                LOCKED, CONTENDED => {},
                else => unreachable, // invalid Lock state
            }

            while (true) {
                switch (self.state.swap(CONTENDED, .Acquire)) {
                    UNLOCKED => return,
                    LOCKED, CONTENDED => Futex.wait(&self.state, CONTENDED, null) catch unreachable,
                    else => unreachable, // invalid Lock State
                }
            }
        }

        pub fn release(self: *Lock) void {
            switch (self.state.swap(UNLOCKED, .Release)) {
                UNLOCKED => unreachable, // unlocked an unlocked Lock
                LOCKED => {},
                CONTENDED => Futex.wake(&self.state, 1),
                else => unreachable, // invalid Lock State
            }
        }
    };

    const Futex = std.Thread.Futex;
};

const Time = struct {

    pub const Clock = struct {
        started: Instant,

        pub fn init() Clock {
            return .{ .started = Instant.now() };
        }

        pub fn now(self: *Clock) u64 {
            return Instant.now().since(self.started);
        }
    };

    pub const Instant = switch (target.os.tag) {
        .windows => WindowsInstant,
        else => PosixInstant,
    };

    const PosixInstant = struct {
        ts: os.timespec,

        pub fn now() Instant {
            var ts: os.timespec = undefined;
            os.clock_gettime(os.CLOCK.MONOTONIC, &ts) catch unreachable;
            return .{ .ts = ts };
        }

        // Returns time since earlier Instant in milliseconds
        pub fn since(self: Instant, earlier: Instant) u64 {
            var secs = self.ts.tv_sec - earlier.ts.tv_sec;
            var nsecs = self.ts.tv_nsec - earlier.ts.tv_nsec;
            if (nsecs < 0) {
                secs += 1;
                nsecs += std.time.ns_per_s;
            }

            var millis = @intCast(u64, secs) * std.time.ms_per_s;
            millis += @intCast(u64, nsecs) / std.time.ns_per_ms;
            return millis;
        }
    };

    const WindowsInstant = @compileError("TODO: QPC");
};

pub const net = struct {
    pub fn tcpConnectToHost(allocator: *Allocator, name: []const u8, port: u16) !Stream {
        const addr_list = try std.net.getAddressList(allocator, name, port);
        defer addr_list.deinit();

        if (addr_list.addrs.len == 0) {
            return error.UnknownHostName;
        }

        for (addr_list.addrs) |addr| {
            return tcpConnectToAddress(addr) catch |err| switch (err) {
                error.ConnectionRefused => continue,
                else => return err,
            };
        }

        return os.ConnectError.ConnectionRefused;
    }

    pub fn tcpConnectToAddress(address: std.net.Address) !Stream {
        const SOCK_CLOEXEC = switch (target.os.tag) {
            .windows => 0,
            else => os.SOCK_CLOEXEC,
        };

        const socket_fd = try os.socket(
            address.any.family,
            os.SOCK_STREAM | os.SOCK_NONBLOCK | SOCK_CLOEXEC,
            os.IPPROTO_TCP,
        );
        errdefer os.closeSocket(socket_fd);

        var net_source = try NetSource.init(socket_fd);
        errdefer net_source.deinit();

        os.connect(socket_fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
            else => return err,
            error.WouldBlock => {
                net_source.waitFor(.write);
                try os.getsockoptError(socket_fd);
            }
        };

        return Stream{ .net_source = net_source };
    }

    pub const Stream = struct {
        net_source: Io.NetSource,

        pub fn close(self: Stream) void {
            const socket_fd = self.net_source.getFd();
            self.net_source.deinit();
            os.closeSocket(socket_fd);
        }

        pub const ReadError = os.ReadError;
        pub const Reader = std.io.Reader(Stream, ReadError, read);

        pub fn reader(self: Stream) Reader {
            return .{ .context = self };
        }

        pub fn read(self: Stream, buffer: []u8) ReadError!usize {
            while (true) {
                return os.read(self.net_source.getFd(), buffer) catch |err| switch (err) {
                    else => return err,
                    error.WouldBlock => {
                        net_source.waitFor(.read);
                        continue;
                    },
                };
            }
        }

        pub const WriteError = os.WriteError;
        pub const Writer = std.io.Writer(Stream, WriteError, write);

        pub fn writer(self: Stream) Writer {
            return .{ .context = self };
        }

        pub fn write(self: Stream, buffer: []const u8) WriteError!usize {
            while (true) {
                return os.write(self.net_source.getFd(), buffer) catch |err| switch (err) {
                    else => return err,
                    error.WouldBlock => {
                        net_source.waitFor(.write);
                        continue;
                    },
                };
            }
        }
    };

    pub const StreamServer = struct {

    };
};

const Io = struct {
    pub const NetSource = struct {
        source: *Source,
        poller: *NetPoller,

        pub fn init(fd: os.fd_t) !NetSource {

            try self.
        }

        pub fn deinit(self: NetSource) void {

        }

        pub fn getFd(self: NetSource) os.fd_t {
            return self.source.fd;
        }

        pub fn waitFor(self: *NetSource, kind: Kind) !void {

        }
    };

    pub const NetPoller = struct {
        cache: Cache,
        reactor: Reactor,
        pending: Atomic(usize) = Atomic(usize).init(0),
        polling: Atomic(bool) = Atomic(bool).init(false),
        notified: Atomic(bool) = Atomic(bool).init(false),

        pub fn notify(self: *NetPoller) void {

        }

        pub fn poll(self: *NetPoller, timeout_ms: u64) ?Task.List {

        }
    };

    const Cache = struct {
        free: ?*Source = null,
        blocks: ?*Block = null,
        allocator: *Allocator,
        
        pub fn init(allocator: *Allocator) Cache {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Cache) void {
            if (self.blocks) |block| block.free(self.allocator);
            self.free = null;
        }

        pub fn alloc(self: *Cache) !*Source {
            const source = self.free orelse blk: {
                const block = try Block.alloc(self.allocator, self.blocks);
                self.blocks = block;
                break :blk &block.array[0];
            };
            self.free = source.next;
            return source;
        }

        pub fn free(self: *Cache, source: *Source) void {
            source.next = self.free;
            self.free = source;
        }
    };

    const Block = struct {
        prev: ?*Block,
        array: [BLOCK_COUNT]Source,

        const BLOCK_SIZE = 64 * 1024;
        const BLOCK_HEADER = @sizeOf(?*Block);
        const BLOCK_COUNT = (BLOCK_SIZE - BLOCK_HEADER) / @sizeOf(Source);

        pub fn alloc(allocator: *Allocator, prev: ?*Block) !*Block {
            const self = try allocator.create(Block);
            self.prev = prev;

            for (self.array) |*source, index| {
                source.next = switch (index + 1) {
                    BLOCK_COUNT => null,
                    else => |i| &self.array[i],
                }
            };

            return self;
        }

        pub fn free(self: *Block, allocator: *Allocator) void {
            var blocks: ?*Block = self;
            while (blocks) |block| {
                blocks = block.prev;
                allocator.destroy(block);
            }
        }
    };

    const Source = struct {
        fd: os.fd_t,
        next: ?*IoSource,
        poll_fd: Reactor.PollFd,
    };

    pub const Kind = enum {
        read = 0,
        write = 1,
    };

    const Reactor = switch (target.os.tag) {
        .windows = WindowsReactor,
        .linux => LinuxReactor,
        else => BSDReactor,
    };

    const LinuxReactor = struct {
        epoll_fd: os.fd_t,
        event_fd: os.fd_t,

        pub fn init(self: *Reactor) !void {
            self.epoll_fd = try os.epoll_create1(os.EPOLL.CLOEXEC);
            errdefer os.close(self.epoll_fd);

            self.event_fd = try os.eventfd(0, os.EFD.CLOEXEC | os.EFD.NONBLOCK);
            errdefer os.close(self.event_fd);

            var event = std.mem.zeroes(os.epoll_event);
            event.events = os.EPOLL.IN;
            try os.epoll_ctl(self.epoll_fd, os.EPOLL.CTL_ADD, self.event_fd, &event);
        }

        pub fn deinit(self: *Reactor) void {
            os.close(self.event_fd);
            os.close(self.epoll_fd);
        }

        pub const PollFd = struct {
            waiters: [2]Atomic(?*Task) = [_]Atomic(?*Task){
                Atomic(?*Task).init(null),
                Atomic(?*Task).init(null),
            },

            var notified: Task = undefined;

            pub fn notify(self: *PollFd, kind: Kind) ?*Task {
                const ptr = &self.waiters[@enumToInt(kind)];

                var waiters = ptr.swap(&notified, .AcqRel);
                if (waiters == &notified)
                    waiters = null;

                return waiters;
            }

            pub fn wait(self: *PollFd, kind: Kind) error{Notified}!void {
                const ptr = &self.waiters[@enumToInt(kind)];

                var waiters = ptr.load(.Acquire);
                var notified = waiters == &notified;

                if (!notified) {
                    assert(waiters == null);
                    var task = Task.init(@frame());
                    suspend {
                        if (ptr.compareAndSwap(
                            null,
                            &task,
                            .AcqRel,
                            .Acquire,
                        )) |updated| {
                            notified = true;
                            resume @frame();
                        }
                    }
                }

                assert(ptr.load(.Acquire) == &notified);
                ptr.store(null, .Monotonic);
                if (notified) return error.Notified;
            }
        };

        pub fn register(self: *Reactor, fd: os.fd_t, poll_fd: *PollFd) !void {
            var event = os.epoll_event{
                .data = .{ .ptr = @ptrToInt(poll_fd) },
                .events = os.EPOLL.IN | os.EPOLL.OUT | os.EPOLL.RDHUP | os.EPOLL.ET,
            };

            return os.epoll_ctl(self.epoll_fd, os.EPOLL.CTL_MOD, fd, &event) catch |e| switch (e) {
                error.FileDescriptorNotRegistered => os.epoll_ctl(self.epoll_fd, os.EPOLL.CTL_ADD, fd, &event),
                else => e,
            };
        }

        pub fn unregister(self: *Reactor, fd: os.fd_t, poll_fd: *PollFd) void {
            _ = poll_fd;
            os.epoll_ctl(self.epoll_fd, os.EPOLL.CTL_DEL, fd, null) catch unreachable;
        }

        pub fn notify(self: *Reactor) void {
            var value: u64 = 0;
            const wrote = os.write(self.event_fd, std.mem.asBytes(&value)) catch unreachable;
            assert(wrote == @sizeOf(u64));
        }

        pub fn poll(self: *Reactor, notified: *bool, timeout_ms: u64) Task.List {
            var events: [128]os.epoll_event = undefined;
            const timeout = std.math.cast(i32, timeout_ms) catch std.math.maxInt(i32);
            const found = os.epoll_wait(self.epoll_fd, &events, timeout);

            var list = Task.List{};
            for (events[0..found]) |ev| {
                const poll_fd = @intToPtr(?*PollFd, ev.data.ptr) orelse {
                    var value: u64 = 0;
                    const read = os.read(self.event_fd, std.mem.asBytes(&value)) catch unreachable;
                    assert(read == @sizeOf(u64));

                    assert(!notified.*);
                    notified.* = true;
                    continue;
                };

                if (ev.events & (os.EPOLL.IN | os.EPOLL.RDHUP | os.EPOLL.ERR | os.EPOLL.HUP) != 0) {
                    if (poll_fd.notify(.read)) |task| {
                        list.push(Task.List.from(task));
                    }
                }

                if (ev.events & (os.EPOLL.OUT | os.EPOLL.ERR | os.EPOLL.HUP) != 0) {
                    if (poll_fd.notify(.write)) |task| {
                        list.push(Task.List.from(task));
                    }
                }
            }

            return list;
        }
    };

    const BSDReactor = @compileError("TODO: kqueue");
    const WindowsReactor = @compileError("TODO: IOCP + AFD");
};
