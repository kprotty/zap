const std = @import("std");

const Lock = @import("./Lock.zig").Lock;
const Futex = @import("./Futex.zig").Futex;
const Thread = @import("./Thread.zig").Thread;

const Pool = @This();

counter: u32 = 0,
max_threads: u16,
spawned: ?*Worker = null,
run_queues: [Priority.Count]GlobalQueue = [_]GlobalQueue{.{}} ** Priority.Count,

pub const InitConfig = struct {
    max_threads: ?u16 = null,
};

pub fn init(config: InitConfig) Pool {
    return .{
        .max_threads = std.math.min(
            std.math.maxInt(u14),
            std.math.max(1, config.max_threads orelse blk: {
                const threads = std.Thread.cpuCount() catch 1;
                break :blk @intCast(u14, threads);
            }),
        ),
    };
}

pub fn deinit(self: *Pool) void {
    self.shutdownWorkers();
    self.joinWorkers();
    self.* = undefined;
}

pub fn shutdown(self: *Pool) void {
    return self.shutdownWorkers();
}

pub const Priority = enum {
    Low = 0,
    Normal = 1,
    High = 2,

    pub const Max = Priority.High;
    pub const Count = @enumToInt(Max) + 1;

    fn toArrayIndex(self: Priority) usize {
        return @enumToInt(Priority.Max) - @enumToInt(self);
    }
};

pub const ScheduleHints = struct {
    priority: Priority = .High,
};

pub fn schedule(self: *Pool, hints: ScheduleHints, batchable: anytype) void {
    const batch = Batch.from(batchable);
    if (batch.isEmpty()) {
        return;
    }

    if (Worker.getCurrent()) |worker| {
        worker.run_queues[hints.priority.toArrayIndex()].push(batch);
    } else {
        self.run_queues[hints.priority.toArrayIndex()].push(batch);
    }

    self.notifyWorkers(false);
}

pub const Batch = struct {
    head: ?*Runnable = null,
    tail: *Runnable = undefined,

    pub fn from(batchable: anytype) Batch {
        return switch (@TypeOf(batchable)) {
            Batch => batchable,
            ?*Runnable => from(batchable orelse return Batch{}),
            *Runnable => {
                batchable.next = null;
                return Batch{
                    .head = batchable,
                    .tail = batchable,
                };
            },
            else => |typ| @compileError(@typeName(typ) ++
                " cannot be converted into " ++
                @typeName(Batch)),
        };
    }

    pub fn isEmpty(self: Batch) bool {
        return self.head == null;
    }

    pub const push = pushBack;
    pub fn pushBack(self: *Batch, batchable: anytype) void {
        const batch = from(batchable);
        if (batch.isEmpty())
            return;

        if (self.isEmpty()) {
            self.* = batch;
        } else {
            self.tail.next = batch.head;
            self.tail = batch.tail;
        }
    }

    pub fn pushFront(self: *Batch, batchable: anytype) void {
        const batch = from(batchable);
        if (batch.isEmpty())
            return;

        if (self.isEmpty()) {
            self.* = batch;
        } else {
            batch.tail.next = self.head;
            self.head = batch.head;
        }
    }

    pub const pop = popFront;
    pub fn popFront(self: *Batch) ?*Runnable {
        const runnable = self.head orelse return null;
        self.head = runnable.next;
        return runnable;
    }
};

pub const Runnable = struct {
    next: ?*Runnable = null,
    runFn: fn (*Runnable) void,

    pub fn init(callback: fn (*Runnable) void) Runnable {
        return .{ .runFn = callback };
    }

    pub fn run(self: *Runnable) void {
        return (self.runFn)(self);
    }
};

/////////////////////////////////////////////////////////////////////////

const Counter = struct {
    idle: u16 = 0,
    spawned: u16 = 0,
    notified: bool = false,
    state: State = .pending,

    const State = enum(u2) {
        pending = 0,
        waking,
        notified,
        shutdown,
    };

    fn pack(self: Counter) u32 {
        return ((@as(u32, @boolToInt(self.notified)) << 0) |
            (@as(u32, @enumToInt(self.state)) << 1) |
            (@as(u32, @intCast(u14, self.idle)) << 3) |
            (@as(u32, @intCast(u14, self.spawned)) << (3+14)));
    }

    fn unpack(value: u32) Counter {
        return .{
            .notified = value & (1 << 0) != 0,
            .state = @intToEnum(State, @truncate(u2, value >> 1)),
            .idle = @truncate(u14, value >> 3),
            .spawned = @truncate(u14, value >> (3+14)),
        };
    }
};

fn notifyWorkers(self: *Pool, _is_waking: bool) void {
    const max_threads = self.max_threads;

    var did_spawn = false;
    var attempts: usize = 5;
    var is_waking = _is_waking;
    var counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));

    while (true) {
        if (counter.state == .shutdown) {
            if (did_spawn)
                self.markShutdown();
            return;
        }

        var do_wake = false;
        var do_spawn = false;

        var new_counter = counter;
        new_counter.notified = true;
        if (is_waking) {
            if (counter.state != .waking)
                std.debug.panic("notifyWorkers(waking) when counter is not", .{});
            if (attempts > 0 and counter.idle > 0) {
                if (did_spawn)
                    new_counter.spawned -= 1;
                new_counter.state = .notified;
                do_wake = true;
            } else if (attempts > 0 and (did_spawn or counter.spawned < max_threads)) {
                if (!did_spawn)
                    new_counter.spawned += 1;
                do_spawn = true;
            } else {
                if (did_spawn)
                    new_counter.spawned -= 1;
                new_counter.state = .pending;
            }
        } else {
            if (counter.state == .pending and counter.idle > 0) {
                new_counter.state = .notified;
                do_wake = true;
            } else if (counter.state == .pending and counter.spawned < max_threads) {
                new_counter.state = .waking;
                new_counter.spawned += 1;
                do_spawn = true;
            } else if (counter.notified) {
                return;
            }
        }

        if (@cmpxchgWeak(
            u32,
            &self.counter,
            counter.pack(),
            new_counter.pack(),
            .Release,
            .Monotonic,
        )) |updated| {
            std.Thread.spinLoopHint();
            counter = Counter.unpack(updated);
            continue;
        }

        is_waking = true;
        if (do_wake) {
            Futex.wake(&self.counter, 1);
            return;
        }

        did_spawn = true;
        if (do_spawn and Thread.spawn(Worker.entry, @ptrToInt(self))) {
            return;
        } else if (!do_spawn) {
            return;
        }

        attempts -= 1;
        std.Thread.spinLoopHint();
        counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));
    }
}

fn suspendWorker(self: *Pool, worker: *Worker) ?bool {
    var is_suspended = false;
    var is_waking = worker.state == .waking;
    var counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));

    while (true) {
        if (counter.state == .shutdown) {
            self.markShutdown();
            return null;
        }

        if (counter.notified or !is_suspended) {
            var new_counter = counter;
            new_counter.notified = false;
            if (counter.state == .notified) {
                if (is_suspended)
                    new_counter.idle -= 1;
                new_counter.state = .waking;
            } else if (counter.notified) {
                if (is_suspended)
                    new_counter.idle -= 1;
                if (is_waking)
                    new_counter.state = .waking;
            } else {
                if (is_waking)
                    new_counter.state = .pending;
                new_counter.idle += 1;
            }

            if (@cmpxchgWeak(
                u32,
                &self.counter,
                counter.pack(),
                new_counter.pack(),
                .Acquire,
                .Monotonic,
            )) |updated| {
                std.Thread.spinLoopHint();
                counter = Counter.unpack(updated);
                continue;
            }

            if (counter.state == .notified)
                return true;
            if (counter.notified)
                return is_waking;

            is_waking = false;
            is_suspended = true;
            counter = new_counter;
        }

        Futex.wait(&self.counter, counter.pack(), null) catch unreachable;
        counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));
    }
}

fn markShutdown(self: *Pool) void {
    var counter = Counter{ .spawned = 1 };
    counter = Counter.unpack(@atomicRmw(u32, &self.counter, .Sub, counter.pack(), .Release));
    if (counter.spawned == 1) {
        Futex.wake(&self.counter, 1);
    }
}

fn shutdownWorkers(self: *Pool) void {
    var counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));
    while (counter.state != .shutdown) {
        var new_counter = counter;
        new_counter.idle = 0;
        new_counter.state = .shutdown;

        if (@cmpxchgWeak(
            u32,
            &self.counter,
            counter.pack(),
            new_counter.pack(),
            .Release,
            .Monotonic,
        )) |updated| {
            counter = Counter.unpack(updated);
            std.Thread.spinLoopHint();
            continue;
        }

        Futex.wake(&self.counter, std.math.maxInt(u32));
        return;
    }
}

fn joinWorkers(self: *Pool) void {
    while (true) {
        const counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Acquire));
        if (counter.spawned == 0)
            break;
        Futex.wait(&self.counter, counter.pack(), null) catch unreachable;
    }

    if (@atomicLoad(?*Worker, &self.spawned, .Acquire)) |top_worker| {
        top_worker.shutdown();
    }
}

const Worker = struct {
    pool: *Pool,
    state: State,
    shutdown_lock: Lock = .{},
    next_target: ?*Worker = null,
    spawned_next: ?*Worker = null,
    run_tick: usize,
    run_queues: [Priority.Count]LocalQueue = [_]LocalQueue{.{}} ** Priority.Count,

    const State = enum(u32) {
        running,
        waking,
        waiting,
        shutdown,
    };

    const is_apple_silicon = std.Target.current.isDarwin() and std.builtin.arch != .x86_64;
    const TLS = if (is_apple_silicon) DarwinTLS else DefaultTLS;

    const DefaultTLS = struct {
        threadlocal var tls: ?*Worker = null;

        fn get() ?*Worker {
            return tls;
        }

        fn set(worker: ?*Worker) void {
            tls = worker;
        }
    };

    const DarwinTLS = struct {
        fn get() ?*Worker {
            const key = getKey();
            const ptr = pthread_getspecific(key);
            return @ptrCast(?*Worker, @alignCast(@alignOf(Worker), ptr));
        }

        fn set(worker: ?*Worker) void {
            const key = getKey();
            const rc = pthread_setspecific(key, @ptrCast(?*c_void, worker));
            std.debug.assert(rc == 0);
        }

        var tls_state: u8 = 0;
        var tls_key: pthread_key_t = undefined;
        const pthread_key_t = c_ulong;
        extern "c" fn pthread_key_create(key: *pthread_key_t, destructor: ?fn (value: *c_void) callconv(.C) void) c_int;
        extern "c" fn pthread_getspecific(key: pthread_key_t) ?*c_void;
        extern "c" fn pthread_setspecific(key: pthread_key_t, value: ?*c_void) c_int;

        fn getKey() pthread_key_t {
            var state = @atomicLoad(u8, &tls_state, .Acquire);
            while (true) {
                switch (state) {
                    0 => state = @cmpxchgWeak(
                        u8,
                        &tls_state,
                        0,
                        1,
                        .Acquire,
                        .Acquire,
                    ) orelse break,
                    1 => {
                        std.os.sched_yield() catch {};
                        state = @atomicLoad(u8, &tls_state, .Acquire);
                    },
                    2 => return tls_key,
                    else => std.debug.panic("failed to get pthread_key_t", .{}),
                }
            }

            const rc = pthread_key_create(&tls_key, null);
            if (rc == 0) {
                @atomicStore(u8, &tls_state, 2, .Release);
                return tls_key;
            }
            
            @atomicStore(u8, &tls_state, 3, .Monotonic);
            std.debug.panic("failed to get pthread_key_t", .{});
        }
    };

    fn getCurrent() ?*Worker {
        return TLS.get();
    }

    fn setCurrent(worker: ?*Worker) void {
        return TLS.set(worker);
    }

    fn entry(pool_ptr: usize) void {
        const pool = @intToPtr(*Pool, pool_ptr);
        var worker: Worker = undefined;
        worker.run(pool);
    }

    fn run(self: *Worker, pool: *Pool) void {
        setCurrent(self);
        self.* = .{
            .pool = pool,
            .state = .waking,
            .run_tick = @ptrToInt(self) *% 31,
        };

        var spawned_next = @atomicLoad(?*Worker, &pool.spawned, .Monotonic);
        while (true) {
            self.spawned_next = spawned_next;
            spawned_next = @cmpxchgWeak(
                ?*Worker,
                &pool.spawned,
                spawned_next,
                self,
                .Release,
                .Monotonic,
            ) orelse break;
        }

        while (true) {
            if (self.pop()) |runnable| {
                if (self.state == .waking)
                    pool.notifyWorkers(true);
                self.state = .running;
                runnable.run();
                continue;
            }
            
            if (pool.suspendWorker(self)) |is_waking| {
                self.state = if (is_waking) .waking else .running;
                continue;
            }

            self.waitForShutdown();
            return;
        }
    }

    fn waitForShutdown(self: *Worker) void {
        while (true) {
            self.shutdown_lock.acquire();

            if (self.state == .shutdown) {
                self.shutdown_lock.release();
                break;
            }

            self.state = .waiting;
            self.shutdown_lock.release();
            Futex.wait(
                @ptrCast(*const u32, &self.state),
                @enumToInt(State.waiting),
                null,
            ) catch unreachable;
        }

        if (self.spawned_next) |next_worker|
            next_worker.shutdown();
    }

    fn shutdown(self: *Worker) void {
        self.shutdown_lock.acquire();
        defer self.shutdown_lock.release();

        const state = self.state;
        @atomicStore(State, &self.state, .shutdown, .Unordered);
        if (state == .waiting)
            Futex.wake(@ptrCast(*const u32, &self.state), 1);
    }

    fn pop(self: *Worker) ?*Runnable {
        self.run_tick +%= 1;

        if (self.run_tick % 257 == 0) {
            if (self.pollWorkers(0)) |runnable|
                return runnable;
        }

        if (self.run_tick % 127 == 0) {
            if (self.pollPool()) |runnable|
                return runnable;
        }

        var priorities: [Priority.Count]Priority = undefined;
        if (self.run_tick % 61 == 0) {
            priorities = [_]Priority{ .Low, .Normal, .High };
        } else if (self.run_tick % 31 == 0) {
            priorities = [_]Priority{ .Normal, .High, .Low };
        } else {
            priorities = [_]Priority{ .High, .Normal, .Low };
        }

        for (priorities) |priority| {
            if (self.run_queues[priority.toArrayIndex()].pop(self.run_tick)) |runnable|
                return runnable;
        }

        const max_attempts = switch (std.builtin.arch) {
            .x86_64 => 32,
            .aarch64 => 16,
            else => 8,
        };

        var steal_attempt: usize = 0;
        while (steal_attempt < max_attempts) : (steal_attempt += 1) {
            if (self.pollPool()) |runnable|
                return runnable;

            if (self.pollWorkers(steal_attempt)) |runnable|
                return runnable;
        }

        if (self.pollPool()) |runnable|
            return runnable;

        return null;
    }

    fn pollPool(self: *Worker) ?*Runnable {
        return self.pollWith(
            std.math.maxInt(usize),
            &self.pool.run_queues,
            "popAndStealGlobal",
        );
    }

    fn pollWorkers(self: *Worker, attempt: usize) ?*Runnable {
        var threads = Counter.unpack(@atomicLoad(u32, &self.pool.counter, .Monotonic)).spawned;
        while (threads > 0) : (threads -= 1) {
            const target = self.next_target orelse @atomicLoad(?*Worker, &self.pool.spawned, .Acquire).?;
            self.next_target = target.spawned_next;

            if (target == self)
                continue;

            if (self.pollWith(attempt, &target.run_queues, "popAndStealLocal")) |runnable|
                return runnable;
        }

        return null;
    }

    fn pollWith(
        self: *Worker,
        attempt: usize,
        target_queues: anytype,
        comptime pollFn: []const u8,
    ) ?*Runnable {
        const priorities: []const Priority = switch (attempt) {
            0 => &[_]Priority{ .High },
            1 => &[_]Priority{ .High, .Normal },
            else => &[_]Priority{ .High, .Normal, .Low },
        };

        for (priorities) |priority| {
            const index = priority.toArrayIndex();
            const our_queue = &self.run_queues[index];
            const target_queue = &target_queues[index];
            if (@field(LocalQueue, pollFn)(our_queue, target_queue)) |runnable|
                return runnable;
        }

        return null;
    }
};

const GlobalQueue = UnboundedQueue;

const LocalQueue = struct {
    buffer: BoundedQueue = .{},
    overflow: UnboundedQueue = .{},

    fn push(self: *LocalQueue, batch: Batch) void {
        if (self.buffer.push(batch)) |overflowed|
            self.overflow.push(overflowed);
    }

    fn pop(self: *LocalQueue, tick: usize) ?*Runnable {
        if (tick % 61 == 0) {
            if (self.buffer.pop()) |runnable|
                return runnable;
        }
        
        if (self.buffer.stealUnbounded(&self.overflow)) |runnable|
            return runnable;

        if (self.buffer.pop()) |runnable|
            return runnable;

        return null;
    }

    fn popAndStealGlobal(self: *LocalQueue, target: *GlobalQueue) ?*Runnable {
        return self.buffer.stealUnbounded(target);
    }

    fn popAndStealLocal(self: *LocalQueue, target: *LocalQueue) ?*Runnable {
        if (self == target)
            return self.pop(1);

        if (self.buffer.stealUnbounded(&target.overflow)) |runnable|
            return runnable;

        if (self.buffer.stealBounded(&target.buffer)) |runnable|
            return runnable;

        return null;
    }
};

const UnboundedQueue = struct {
    head: ?*Runnable = null,
    tail: usize = 0,
    stub: Runnable = Runnable.init(undefined),

    fn push(self: *UnboundedQueue, batch: Batch) void {
        if (batch.isEmpty()) return;
        const head = @atomicRmw(?*Runnable, &self.head, .Xchg, batch.tail, .AcqRel);
        const prev = head orelse &self.stub;
        @atomicStore(?*Runnable, &prev.next, batch.head, .Release);
    }

    fn tryAcquireConsumer(self: *UnboundedQueue) ?Consumer {
        var tail = @atomicLoad(usize, &self.tail, .Monotonic);
        while (true) : (std.Thread.spinLoopHint()) {

            const head = @atomicLoad(?*Runnable, &self.head, .Monotonic);
            if (head == null or head == &self.stub)
                return null;

            if (tail & 1 != 0)
                return null;
            tail = @cmpxchgWeak(
                usize,
                &self.tail,
                tail,
                tail | 1,
                .Acquire,
                .Monotonic,
            ) orelse return Consumer{
                .queue = self,
                .tail = @intToPtr(?*Runnable, tail) orelse &self.stub,
            };
        }
    }

    const Consumer = struct {
        queue: *UnboundedQueue,
        tail: *Runnable,

        fn release(self: Consumer) void {
            @atomicStore(usize, &self.queue.tail, @ptrToInt(self.tail), .Release);
        }

        fn pop(self: *Consumer) ?*Runnable {
            var tail = self.tail;
            var next = @atomicLoad(?*Runnable, &tail.next, .Acquire);
            if (tail == &self.queue.stub) {
                tail = next orelse return null;
                self.tail = tail;
                next = @atomicLoad(?*Runnable, &tail.next, .Acquire);
            }

            if (next) |runnable| {
                self.tail = runnable;
                return tail;
            }

            const head = @atomicLoad(?*Runnable, &self.queue.head, .Monotonic);
            if (tail != head) {
                return null;
            }

            self.queue.push(Batch.from(&self.queue.stub));
            if (@atomicLoad(?*Runnable, &tail.next, .Acquire)) |runnable| {
                self.tail = runnable;
                return tail;
            }

            return null;
        }
    };
};

const BoundedQueue = struct {
    head: Pos = 0,
    tail: Pos = 0,
    buffer: [capacity]*Runnable = undefined,

    const Pos = std.meta.Int(.unsigned, std.meta.bitCount(usize) / 2);
    const capacity = 64;
    comptime {
        std.debug.assert(capacity <= std.math.maxInt(Pos));
    }

    fn push(self: *BoundedQueue, _batch: Batch) ?Batch {
        var batch = _batch;
        if (batch.isEmpty()) {
            return null;
        }

        var tail = self.tail;
        var head = @atomicLoad(Pos, &self.head, .Monotonic);
        while (true) {
            if (batch.isEmpty())
                return null;

            if (tail -% head < self.buffer.len) {
                while (tail -% head < self.buffer.len) {
                    const runnable = batch.pop() orelse break;
                    @atomicStore(*Runnable, &self.buffer[tail % self.buffer.len], runnable, .Unordered);
                    tail +%= 1;
                }

                @atomicStore(Pos, &self.tail, tail, .Release);
                std.Thread.spinLoopHint();
                head = @atomicLoad(Pos, &self.head, .Monotonic);
                continue;
            }

            const new_head = head +% @intCast(Pos, self.buffer.len / 2);
            if (@cmpxchgWeak(
                Pos,
                &self.head,
                head,
                new_head,
                .Acquire,
                .Monotonic,
            )) |updated| {
                head = updated;
                continue;
            }

            var overflowed = Batch{};
            while (head != new_head) : (head +%= 1) {
                const runnable = self.buffer[head % self.buffer.len];
                overflowed.pushBack(Batch.from(runnable));
            }

            overflowed.pushBack(batch);
            return overflowed;
        }
    }

    fn pop(self: *BoundedQueue) ?*Runnable {
        var tail = self.tail;
        var head = @atomicLoad(Pos, &self.head, .Monotonic);
        
        while (tail != head) : (std.Thread.spinLoopHint()) {
            head = @cmpxchgWeak(
                Pos,
                &self.head,
                head,
                head +% 1,
                .Acquire,
                .Monotonic,
            ) orelse return self.buffer[head % self.buffer.len];
        }

        return null;
    }

    fn stealUnbounded(self: *BoundedQueue, target: *UnboundedQueue) ?*Runnable {
        var consumer = target.tryAcquireConsumer() orelse return null;
        defer consumer.release();

        const first_runnable = consumer.pop();
        const head = @atomicLoad(Pos, &self.head, .Monotonic);
        const tail = self.tail;

        var new_tail = tail;
        while (new_tail -% head < self.buffer.len) {
            const runnable = consumer.pop() orelse break;
            @atomicStore(*Runnable, &self.buffer[new_tail % self.buffer.len], runnable, .Unordered);
            new_tail +%= 1;
        }

        if (new_tail != tail)
            @atomicStore(Pos, &self.tail, new_tail, .Release);
        return first_runnable;
    }

    fn stealBounded(self: *BoundedQueue, target: *BoundedQueue) ?*Runnable {
        if (self == target)
            return self.pop();

        const head = @atomicLoad(Pos, &self.head, .Monotonic);
        const tail = self.tail;
        if (tail != head)
            return self.pop();

        var target_head = @atomicLoad(Pos, &target.head, .Monotonic);
        while (true) {
            const target_tail = @atomicLoad(Pos, &target.tail, .Acquire);
            const target_size = target_tail -% target_head;
            if (target_size == 0)
                return null;

            var steal = target_size - (target_size / 2);
            if (steal > target.buffer.len / 2) {
                std.Thread.spinLoopHint();
                target_head = @atomicLoad(Pos, &target.head, .Monotonic);
                continue;
            }

            const first_runnable = @atomicLoad(*Runnable, &target.buffer[target_head % target.buffer.len], .Unordered);
            var new_target_head = target_head +% 1;
            var new_tail = tail;
            steal -= 1;

            while (steal > 0) : (steal -= 1) {
                const runnable = @atomicLoad(*Runnable, &target.buffer[new_target_head % target.buffer.len], .Unordered);
                new_target_head +%= 1;
                @atomicStore(*Runnable, &self.buffer[new_tail % self.buffer.len], runnable, .Unordered);
                new_tail +%= 1;
            }

            if (@cmpxchgWeak(
                Pos,
                &target.head,
                target_head,
                new_target_head,
                .AcqRel,
                .Monotonic,
            )) |updated| {
                std.Thread.spinLoopHint();
                target_head = updated;
                continue;
            }

            if (new_tail != tail)
                @atomicStore(Pos, &self.tail, new_tail, .Release);
            return first_runnable;
        }
    }
};
