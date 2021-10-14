const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const builtin = @import("builtin");
const target = builtin.target;
const single_threaded = builtin.single_threaded;

const Loop = @This();

started: Instant,
workers: []Worker,
net_poller: NetPoller,
thread_pool: ThreadPool,
idle: Atomic(usize) = Atomic(usize).init(0),
searching: Atomic(usize) = Atomic(usize).init(0),
injecting: Atomic(usize) = Atomic(usize).init(0),

pub const Task = struct {
    next: ?*Task = null,
    frame: ?anyframe = null,

    pub fn init(frame: anyframe) Task {
        return .{ .frame = frame };
    }
};

const Batch = struct {
    len: usize = 0,
    head: ?*Task = null,
    tail: ?*Task = null,

    fn from(task: *Task) Batch {
        task.next = null;
        return .{
            .len = 1,
            .head = task,
            .tail = task,
        };
    }

    fn push(self: *Batch, batch: Batch) void {
        if (batch.len == 0)
            return;

        const prev = if (self.tail) |tail| &tail.next else &self.head;
        prev.* = batch.head orelse unreachable;
        self.tail = batch.tail orelse unreachable;
        self.len += batch.len;
    }

    fn pop(self: *Batch) ?*Task {
        self.len = std.math.sub(usize, self.len, 1) catch return null;

        if (self.len == 0) self.tail = null;
        const task = self.head orelse unreachable;
        self.head = task.next;
        return task;
    }
};

pub fn schedule(self: *Loop, task: *Task) void {
    const thread = Thread.current orelse return self.inject(Batch.from(task));
    const worker = thread.worker orelse unreachable; // thread running without a worker

    worker.run_queue.push(task);
    self.notify();
}

fn inject(self: *Loop, batch: Batch) void {
    const injecting = self.injecting.fetchAdd(1, .Monotonic);
    const worker = &self.workers[injecting % self.workers.len];

    worker.run_queue.inject(batch);
    std.atomic.fence(.SeqCst);
    self.notify();
}

fn notify(self: *Loop) void {
    if (self.peekIdleWorker() == null)
        return;

    if (self.searching.load(.Monotonic) > 0)
        return;

    if (self.searching.compareAndSwap(0, 1, .Acquire, .Monotonic)) |_|
        return;

    if (self.popIdleWorker()) |worker| blk: {
        return self.thread_pool.wake(worker) catch {
            self.pushIdleWorker(worker);
            break :blk;
        };
    }

    const searching = self.searching.fetchSub(1, .Release);
    assert(searching > 0);
}

const Idle = packed struct {
    index: Count = 0,
    aba: Count = 0,

    const max_index = std.math.maxInt(Count) - 1;
    const Count = std.math.Int(.unsigned, @bitSizeOf(usize) / 2);
};

const Worker = struct {
    idle_next: Atomic(Idle.Count) = Atomic(Idle.Count).init(0),
    run_queue: Queue = .{}, 
};

fn pushIdleWorker(self: *Loop, worker: *Worker) void {
    const worker_index = (@ptrToInt(worker) - @ptrToInt(self.workers.ptr)) / @sizeOf(Worker);
    assert(worker_index <= Idle.max_index);
    assert(worker_index < self.workers.len);

    var idle = @bitCast(Idle, self.idle.load(.Monotonic));
    while (true) {
        const prev_index = idle.index;
        worker.idle_next.store(prev_index, .Monotonic);

        idle = @bitCast(Idle, self.idle.tryCompareAndSwap(
            @bitCast(usize, idle),
            @bitCast(usize, Idle{
                .index = worker_index + 1,
                .aba = idle.aba +% 1,
            }),
            .Release,
            .Monotonic,
        ) orelse return);
    }
}

fn peekIdleWorker(self: *Loop) ?*Worker {
    const idle = @bitCast(Idle, self.idle.load(.Acquire));

    const worker_index = std.math.sub(Idle.Count, idle.index, 1) catch return null;
    assert(worker_index <= Idle.max_index);
    assert(worker_index < self.workers.len);

    return &self.workers[worker_index];
}

fn popIdleWorker(self; *Loop) ?*Worker {
    var idle = @bitCast(Idle, self.idle.load(.Acquire));
    while (true) {
        const worker_index = std.math.sub(Idle.Count, idle.index, 1) catch return null;
        assert(worker_index <= Idle.max_index);
        assert(worker_index < self.workers.len);

        const worker = &self.workers[worker_index];
        const next_index = worker.idle_next.load(.Monotonic);

        idle = @bitCast(Idle, self.idle.compareAndSwap(
            @bitCast(usize, idle),
            @bitCast(usize, Idle{
                .index = next_index,
                .aba = idle.aba,
            }),
            .AcqRel,
            .Acquire,
        ) orelse return worker);
    }
}

const Thread = struct {
    loop: *Loop,
    worker: ?*Worker,
    tick: u8,
    xorshift: u32,
    searching: bool,

    threadlocal var current: ?*Thread = null;

    fn run(loop: *Loop, worker: *Worker) void {
        const rng_seed = @ptrToInt(worker) *% 31;
        
        var self = Thread{
            .loop = loop,
            .worker = worker,
            .tick = @truncate(u8, rng_seed),
            .xorshift = @truncate(u32, rng_seed) | 1,
            .searching = true,
        };

        const old_current = current;
        current = &self;
        defer current = old_current;

        while (self.poll()) |task| {
            self.tick +%= 1;
            const frame = task.frame orelse unreachable;
            resume frame;
        }
    }
    
    fn poll(self: *Thread) ?*Task {
        while (true) {
            {
                const worker = self.worker orelse unreachable; // thread running without a worker
                if (self.pollQueues(worker)) |task| {
                    return task;
                }

                self.loop.pushIdleWorker(worker);
                self.worker = null;
            }

            const was_searching = self.searching;
            if (was_searching) {
                var searching = self.loop.searching.fetchSub(1, .SeqCst);
                assert(searching > 0);
                self.searching = false;

                if (searching == 1 and self.pollPending()) blk: {
                    self.worker = self.loop.popIdleWorker() orelse break :blk;

                    if (was_searching) {
                        searching = self.loop.searching.fetchAdd(1, .Monotonic);
                        assert(searching < self.loop.workers.len);
                        self.searching = true;
                    }

                    continue;
                }
            }

            var batch = self.net_poller.poll(null);
            if (batch.len > 0) blk: {
                self.worker = self.loop.popIdleWorker() orelse {
                    self.loop.inject(batch);
                    break :blk;
                };

                if (was_searching) {
                    searching = self.loop.searching.fetchAdd(1, .Monotonic);
                    assert(searching < self.loop.workers.len);
                    self.searching = true;
                }

                const task = batch.pop() orelse unreachable;
                self.worker.?.run_queue.fill(batch);
                return task;
            }

            self.worker = self.loop.thread_pool.wait() catch return null;
            self.searching = true;
            continue;
        }
    }

    fn pollPending(self: *Thread) bool {
        
    }

    fn pollQueues(self: *Thread, worker: *Worker) ?*Task {

    }

    fn pollShared(self: *Thread, worker: *Worker) ?*Task {

    }

    fn pollSteal(self: *Thread, worker: *Worker) error{Empty, Contended}!*Task {

    }
};

const ThreadPool = struct {
    lock: Lock = .{},
    spawned: usize = 0,
    max_threads: usize,
    running: bool = true,
    idle: IdleQueue = .{},
    join_event: ?*Event = null,

    const IdleQueue = std.TailQueue(struct {
        event: Event = .{},
        worker: ?*Worker = null,

        fn wait(self: *@This()) error{Shutdown}!*Worker {
            self.event.wait();
            return self.worker orelse error.Shutdown;
        }

        fn wake(self: *@This(), worker: ?*Worker) void {
            self.worker = worker;
            self.event.wake();
        }
    });

    fn wait(self: *ThreadPool) error{Shutdown}!*Worker {
        var idle_node: IdleQueue.Node = undefined;
        {
            self.lock.acquire();
            defer self.lock.release();

            if (!self.running)
                return error.Shutdown;

            idle_node = .{ .data = .{} };
            self.idle.prepend(&idle_node);
        }
        return idle_node.data.wait();
    }

    fn wake(self: *ThreadPool, worker: *Worker) !void {
        const Wake = union(enum) {
            spawned: usize,
            notified: ?*IdleQueue.Node,
        };

        switch (blk: {
            self.lock.acquire();
            defer self.lock.release();

            if (!self.running)
                return error.Shutdown;

            if (self.idle.popFirst()) |idle_node|
                break :blk Wake{ .notified = idle_node };

            if (self.spawned == self.max_threads)
                return std.Thread.SpawnError.ThreadQuotaExceeded;
            
            const pos = self.spawned;
            self.spawned += 1;
            break :blk Wake{ .spawned = pos };
        }) {
            .notified => |idle_node| idle_node.data.wake(worker),
            .spawned => |pos| {
                if (pos == 0)
                    return self.run(worker);

                if (single_threaded)
                    @panic("Tried to spawn a thread in single_threaded");

                errdefer self.finish();
                const thread = try std.Thread.spawn(.{}, ThreadPool.run, .{self, worker});
                thread.detach();
            },
        }
    }

    fn run(self: *ThreadPool, worker: *Worker) void {
        defer self.finish();
        return Thread.run(worker);
    }

    fn shutdown(self: *ThreadPool) void {
        var idle = IdleQueue{};
        defer while (idle.popFirst()) |idle_node|
            idle_node.data.wake(null);

        self.lock.acquire();
        defer self.lock.release();

        self.running = false;
        std.mem.swap(IdleQueue, &self.idle, &idle);
    }

    fn finish(self: *ThreadPool) void {
        var join_event: ?*Event = null;
        defer if (join_event) |event|
            event.wake();

        self.lock.acquire();
        defer self.lock.release();

        assert(self.spawned > 0);
        self.spawned -= 1;

        if (self.spawned == 0)
            std.mem.swap(?*Event, &self.join_event, &join_event);
    }

    fn join(self: *ThreadPool) void {
        var join_event: ?Event = null;
        defer if (join_event) |event|
            event.wait();

        self.lock.acquire();
        defer self.lock.release();

        assert(self.join_event == null);
        if (self.spawned == 0)
            return;
        
        join_event = Event{};
        self.join_event = &join_event.?;
    }
};

const Lock = struct {
    state: Atomic(u32) = Atomic(u32).init(UNLOCKED),

    const UNLOCKED = 0;
    const LOCKED = 1;
    const CONTENDED = 2;

    fn acquire(self: *Lock) void {
        var lock_state = self.state.swap(LOCKED, .Acquire);
        if (lock_state == UNLOCKED)
            return;

        while (true) : (std.Thread.Futex.wait(&self.state, CONTENDED, null) catch unreachable) {
            var spin: u8 = 100;
            while (true) {
                var state = self.state.load(.Monotonic);
                if (state == UNLOCKED)
                    state = self.state.compareAndSwap(state, lock_state, .Acquire, .Monotonic) orelse return;
                if (state == CONTENDED)
                    break;

                assert(state == LOCKED);
                std.atomic.spinLoopHint();
                spin = std.math.sub(u8, spin, 1) catch break;
            }

            lock_state = CONTENDED;
            if (self.state.swap(lock_state, .Acquire) == UNLOCKED)
                return;
        }
    }

    fn release(self: *Lock) void {
        switch (self.state.swap(UNLOCKED, .Release)) {
            UNLOCKED => unreachable, // unlocked an unlocked Lock
            LOCKED => {},
            CONTENDED => std.Thread.Futex.wake(&self.state, 1),
            else => unreachable, // invalid Lock state
        }
    }
};

const Event = struct {
    state: Atomic(u32) = Atomic(u32).init(UNSET),

    const UNSET = 0;
    const WAITING = 1;
    const SET = 2;

    fn wait(self: *Event) void {
        if (self.state.compareAndSwap(UNSET, WAITING, .Acquire, .Acquire)) |state| {
            assert(state == SET);
            return;
        }

        while (true) {
            std.Thread.Futex.wait(&self.state, WAITING, null) catch unreachable;
            switch (self.state.load(.Acquire)) {
                UNSET => unreachable, // waiting while event was reset
                WAITING => continue,
                SET => return,
                else => unreachable, // invalid Event state
            }
        }
    }

    fn wake(self: *Event) void {
        switch (self.state.swap(SET, .Release)) {
            UNSET => {},
            WAITING => std.Thread.Futex.wake(&self.state, 1),
            SET => unreachable, // Event was set multiple times
            else => unreachable, // invalid Event state
        }
    }
};

const Instant = switch (target.os.tag) {
    .windows => WindowsInstant,
    .macos, .ios, .tvos, .watchos => PosixInstant(os.CLOCK.UPTIME_RAW),
    .freebsd, .dragonfly => PosixInstant(os.CLOCK.UPTIME_FAST),
    .openbsd, linux => PosixInstant(os.CLOCK.BOOTTIME),
    else => PosixInstant(os.CLOCK.MONOTONIC),
};

fn PosixInstant(comptime clock_id: u32) type {
    return struct {
        ts: os.timespec,

        pub fn now() Instant {
            var ts: os.timespec = undefined;
            os.clock_gettime(clock_id, &ts) catch unreachable;
            return .{ .ts = ts };
        }

        pub fn order(self: Instant, other: Instant) std.math.Order {
            return switch (std.math.order(self.ts.tv_sec, other.ts.tv_sec)) {
                .eq => std.math.order(self.ts.tv_nsec, other.ts.tv_nsec),
                else => |ord| ord,
            };
        }

        pub fn since(self: Instant, earlier: Instant) u64 {
            switch (self.order(earlier)) {
                .eq => return 0,
                .lt => unreachable,
                .gt => {},
            }

            // The only permutation ive found that llvm makes branchless
            var ts: os.timespec = undefined;
            if (self.ts.tv_nsec - earlier.ts.tv_nsec < 0) {
                ts.tv_sec = self.ts.tv_sec - earlier.ts.tv_sec - 1;
                ts.tv_nsec = self.ts.tv_nsec - earlier.ts.tv_nsec + std.time.ns_per_s;
            } else {
                ts.tv_sec = self.ts.tv_sec - earlier.ts.tv_sec;
                ts.tv_nsec = self.ts.tv_nsec - earlier.ts.tv_nsec;
            }

            var elapsed_ms = @intCast(u64, ts.tv_sec) * std.time.ms_per_s;
            elapsed_ms += @intCast(u32, ts.tv_nsec) / std.time.ns_per_ms;
            return elapsed_ms; 
        }
    };
}

const WindowsInstant = struct {
    qpc: u64,

    pub fn now() Instant {
        return .{ .qpc = os.windows.QueryPerformanceCounter() };
    }

    pub fn order(self: Instant, other: Instant) std.math.Order {
        return std.math.order(self.qpc, other.qpc);
    }

    pub fn since(self: Instant, earlier: Instant) u64 {
        switch (self.order(earlier)) {
            .eq => return 0,
            .lt => unreachable,
            .gt => {},
        }

        const frequency = os.windows.QueryPerformanceFrequency();
        const counter = self.qpc - earlier.qpc;
        const resolution = ;

        const common_freq = 10_000_000;
        if (frequency == common_freq) {
            return counter / (common_freq / std.time.ns_per_ms);
        }

        var scaled: u64 = undefined;
        if (!@mulWithOverflow(u64, counter, std.time.ns_per_ms, &scaled)) {
            return scaled / frequency;
        }

        const part = ((counter % frequency) * std.time.ns_per_ms) / frequency;
        const whole = (counter / frequency) * std.time.ns_per_ms;
        return whole + part;
    }
};

const IoKind = enum {
    read = 0,
    write = 1,
};

const IoDriver = switch (target.os.tag) {
    .freebsd, .openbsd, .netbsd, .dragonfly => BSDIoDriver,
    .macos, .ios, .tvos, .watchos => DarwinIoDriver,
    .windows => WindowsIoDriver,
    .linux => LinuxIoDriver,
    else => PosixIoDriver,
};

const LinuxIoDriver = PosixIoDriverImpl(struct {
    epoll_fd: os.fd_t,
    event_fd: os.fd_t,

    const Self = @This();

    fn init() !Self {

    }

    fn deinit(self: Self) void {

    }

    fn register(self: Self, fd: os.fd_t, ptr: usize) !void {

    }

    fn unregister(self: Self, fd: os.fd_t) void {

    }

    fn notify(self: Self) void {

    }
    
    fn poll(self: Self, notified: *bool, timeout_ms: ?u64) Batch {

    }
});

fn PosixIoDriverImpl(comptime IoDriverImpl: type) type {
    return struct {
        impl: IoDriverImpl,
        lock: Lock = .{},
        free: ?*IoNode = null,
        blocks: ?*IoBlock = null,
        allocator: *Allocator,

        const IoNode = struct {
            fd: os.fd_t,
            next: ?*IoNode = null,
            waiters: [2]Atomic(?*Task) = [_]Atomic(?*Task){
                Atomic(?*Task).init(null),
                Atomic(?*Task).init(null),
            },

            var closed: Task = undefined;
            var notified: Task = undefined;

            fn wait(self: *IoNode, kind: IoKind, driver: *IoDriver) error{Closed}!void {

            }

            fn wake(self: *IoNode, kind: IoKind, close: bool) ?*Task {

            }
        };

        pub const IoSource = struct {
            node: *IoNode,
            poller: *IoPoller,

            pub fn init(fd: os.fd_t) !IoSource {

            }

            pub fn deinit(self: IoSource) void {

            }

            pub fn getFd(self: IoSource) os.fd_t {
                return self.node.fd;
            }

            pub fn wait(self: IoSource, kind: IoKind) error{Closed}!void {
                
            }
        };

        pub const Socket = struct {
            source: IoSource,

            pub fn init(domain: u32, sock_type: u32, protocol: u32) !Socket {

            }

            pub fn deinit(self: Socket) void {

            }

            pub fn getHandle(self: Socket) os.socket_t {

            }

            pub fn listen(self: Socket, backlog: u16) !void {

            }

            pub fn bind(self: Socket, addr: std.net.Address) !void {

            }

            pub fn accept(self: Socket, addr: *std.net.Address) !Socket {

            }

            pub fn connect(self: Socket, addr: std.net.Address) !void {

            }

            pub fn sendmsg(self: Socket, )
        };
    };
}