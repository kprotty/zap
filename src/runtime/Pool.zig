const std = @import("std");

const Lock = @import("./Lock.zig").Lock;
const Futex = @import("./Futex.zig").Futex;
const Thread = @import("./Thread.zig").Thread;

const Pool = @This();

counter: u32 = 0,
max_threads: u16,
join_id: u32 = 0,
spawned: ?*Worker = null,
run_queues: [ScheduleHints.Priority.max]GlobalQueue = [_]GlobalQueue{.{}} ** ScheduleHints.Priority.max,

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

pub const ScheduleHints = struct {
    priority: Priority = .Normal,

    pub const Priority = enum {
        High = 0,
        Normal = 1,
        Low = 2,

        const max = 3;
    };
};

pub fn schedule(self: *Pool, hints: ScheduleHints, batchable: anytype) void {
    const batch = Batch.from(batchable);
    if (batch.isEmpty()) {
        return;
    }

    const priority = @enumToInt(hints.priority);
    if (Worker.getCurrent()) |worker| {
        worker.run_queues[priority].push(batch);
    } else {
        self.run_queues[priority].push(batch);
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
    state: State = .pending,
    waking: bool = false,
    polling: bool = false,

    const State = enum(u2) {
        pending = 0,
        notified,
        signalled,
        shutdown,
    };

    fn pack(self: Counter) u32 {
        return ((@as(u32, @boolToInt(self.waking)) << 0) |
            (@as(u32, @boolToInt(self.polling)) << 1) |
            (@as(u32, @enumToInt(self.state)) << 2) |
            (@as(u32, @intCast(u14, self.idle)) << 4) |
            (@as(u32, @intCast(u14, self.spawned)) << 18));
    }

    fn unpack(value: u32) Counter {
        return .{
            .waking = (value & (1 << 0)) != 0,
            .polling = (value & (1 << 1)) != 0,
            .state = @intToEnum(State, @truncate(u2, value >> 2)),
            .idle = @truncate(u14, value >> 4),
            .spawned = @truncate(u14, value >> 18),
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

        if (is_waking and !counter.waking)
            std.debug.panic("is_waking when counter isnt", .{});

        var new_counter = counter;
        if (is_waking) {
            if (attempts > 0 and did_spawn) {
                new_counter.state = .notified;
                new_counter.waking = true;
            } else if (attempts > 0 and counter.idle > 0) {
                new_counter.state = .signalled;
                new_counter.waking = true;
                new_counter.idle -= 1;
            } else if (attempts > 0 and counter.spawned < max_threads) {
                new_counter.state = .notified;
                new_counter.waking = true;
                new_counter.spawned += 1;
            } else {
                new_counter.state = .notified;
                new_counter.waking = false;
                if (did_spawn)
                    new_counter.spawned -= 1;
            }
        } else {
            if (!counter.waking and counter.idle > 0) {
                new_counter.state = .signalled;
                new_counter.waking = true;
                new_counter.idle -= 1;
            } else if (!counter.waking and counter.spawned < max_threads) {
                new_counter.state = .notified;
                new_counter.waking = true;
                new_counter.spawned += 1;
            } else if (counter.state == .pending) {
                new_counter.state = .notified;
            } else {
                return;
            }
        }

        if (@cmpxchgWeak(
            u32,
            &self.counter,
            counter.pack(),
            new_counter.pack(),
            .Monotonic,
            .Monotonic,
        )) |updated| {
            std.Thread.spinLoopHint();
            counter = Counter.unpack(updated);
            continue;
        }

        is_waking = true;
        if (new_counter.state == .signalled) {
            Futex.wake(&self.counter, 1);
            return;
        }

        did_spawn = did_spawn or (new_counter.spawned > counter.spawned);
        if (did_spawn) {
            if (Thread.spawn(Worker.entry, @ptrToInt(self))) {
                return;
            }
        } else {
            return;
        }

        attempts -= 1;
        std.Thread.spinLoopHint();
        counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));
    }
}

fn suspendWorker(self: *Pool, worker: *Worker) ?bool {
    var is_suspended = false;
    var is_waking = worker.is_waking;
    var counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));

    while (true) {
        if (counter.state == .shutdown) {
            self.markShutdown();
            return null;
        }

        if (!is_suspended or counter.state == .signalled) {
            var new_counter = counter;
            if (counter.state == .signalled) {
                if (is_waking)
                    std.debug.panic("signalled when suspend(waking)", .{});
                new_counter.state = .pending;
                new_counter.waking = true;
            } else if (counter.state == .notified) {
                new_counter.state = .pending;
                if (is_waking)
                    new_counter.waking = true;
            } else {
                if (is_suspended)
                    std.debug.panic("trying to suspend when already suspended", .{});
                new_counter.idle += 1;
                if (is_waking)
                    new_counter.waking = false;
            }

            if (@cmpxchgWeak(
                u32,
                &self.counter,
                counter.pack(),
                new_counter.pack(),
                .Monotonic,
                .Monotonic,
            )) |updated| {
                std.Thread.spinLoopHint();
                counter = Counter.unpack(updated);
                continue;
            }

            if (counter.state == .signalled)
                return true;
            if (counter.state == .notified)
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
            .Monotonic,
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

    var workers = @atomicLoad(?*Worker, &self.spawned, .Acquire);
    while (workers) |worker| {
        workers = worker.spawned_next;
        const thread = worker.thread;
        worker.shutdown();
        thread.join();
    }
}

const Worker = struct {
    id: u32,
    pool: *Pool,
    thread: Thread,
    spawned_next: ?*Worker = null,
    run_queues: [ScheduleHints.Priority.max]LocalQueue = [_]LocalQueue{.{}} ** ScheduleHints.Priority.max,
    xorshift: u32,
    is_waking: bool,

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

    fn entry(thread: Thread, pool_ptr: usize) void {
        const pool = @intToPtr(*Pool, pool_ptr);
        var worker: Worker = undefined;
        worker.run(pool, thread);
    }

    fn run(self: *Worker, pool: *Pool, thread: Thread) void {
        setCurrent(self);
        self.* = .{
            .id = 0,
            .pool = pool,
            .thread = thread,
            .xorshift = @truncate(u32, @ptrToInt(self) >> @sizeOf(usize)) | 1,
            .is_waking = true,
        };

        var spawned_next = @atomicLoad(?*Worker, &pool.spawned, .Acquire);
        while (true) {
            self.spawned_next = spawned_next;
            if (spawned_next) |next_worker| {
                if (@addWithOverflow(u32, next_worker.id, 1, &self.id))
                    std.debug.panic("too many workers spawned", .{});
            } else {
                self.id = 1;
            }

            spawned_next = @cmpxchgWeak(
                ?*Worker,
                &pool.spawned,
                spawned_next,
                self,
                .Release,
                .Acquire,
            ) orelse break;
        }

        while (true) {
            if (self.poll()) |runnable| {
                if (self.is_waking) pool.notifyWorkers(true);
                self.is_waking = false;
                runnable.run();
            } else if (pool.suspendWorker(self)) |is_waking| {
                self.is_waking = is_waking;
            } else {
                return self.waitForShutdown();
            }
        }
    }

    fn waitForShutdown(self: *Worker) void {
        while (true) {
            const join_id = @atomicLoad(u32, &self.pool.join_id, .Acquire);
            if (join_id == self.id) {
                break;
            } else {
                Futex.wait(&self.pool.join_id, join_id, null) catch unreachable;
            }
        }
    }

    fn shutdown(self: *Worker) void {
        @atomicStore(u32, &self.pool.join_id, self.id, .Release);
        Futex.wake(&self.pool.join_id, std.math.maxInt(u32));
    }

    fn poll(self: *Worker) ?*Runnable {
        var attempt: usize = 0;
        while (attempt < 5) : (attempt += 1) {
            if (self.pollWorker(self, attempt)) |runnable| {
                return runnable;
            }

            const counter = Counter.unpack(@atomicLoad(u32, &self.pool.counter, .Monotonic));
            const num_threads = @as(@TypeOf(self.xorshift), counter.spawned);
            const skip = blk: {
                self.xorshift ^= self.xorshift << 13;
                self.xorshift ^= self.xorshift >> 17;
                self.xorshift ^= self.xorshift << 5;
                break :blk (self.xorshift % std.math.max(1, num_threads / 2));
            };

            var iter = skip + num_threads;
            var next_target: ?*Worker = null;
            while (iter > 0) : (iter -= 1) {
                const target = next_target orelse @atomicLoad(?*Worker, &self.pool.spawned, .Acquire).?;
                next_target = target.spawned_next;
                if (iter > num_threads) continue;
                if (target == self) continue;
                if (self.pollWorker(target, attempt)) |runnable| {
                    return runnable;
                }
            }

            if (self.pollPool(self.pool, attempt)) |runnable| {
                return runnable;
            }
        }

        return null;
    }

    fn pollWorker(self: *Worker, target: *Worker, attempt: usize) ?*Runnable {
        if (self == target and attempt > 0) {
            return null;
        }

        var queue: usize = 0;
        while (queue < std.math.min(attempt + 1, self.run_queues.len)) : (queue += 1) {
            const our_queue = &self.run_queues[queue];
            const target_queue = &target.run_queues[queue];
            if (our_queue.popAndSteal(target_queue)) |runnable| {
                return runnable;
            }
        }

        return null;
    }

    fn pollPool(self: *Worker, pool: *Pool, attempt: usize) ?*Runnable {
        var queue: usize = 0;
        while (queue < std.math.min(attempt + 1, self.run_queues.len)) : (queue += 1) {
            const pool_queue = &pool.run_queues[queue];
            const our_queue = &self.run_queues[queue];
            if (our_queue.popAndStealGlobal(pool_queue)) |runnable| {
                return runnable;
            }
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

    fn pop(self: *LocalQueue) ?*Runnable {
        if (self.buffer.pop()) |runnable|
            return runnable;
        if (self.buffer.stealUnbounded(&self.overflow)) |runnable|
            return runnable;
        return null;
    }

    fn popAndSteal(self: *LocalQueue, target: *LocalQueue) ?*Runnable {
        if (self.buffer.stealBounded(&target.buffer)) |runnable|
            return runnable;
        if (self.buffer.stealUnbounded(&target.overflow)) |runnable|
            return runnable;
        return null;
    }

    fn popAndStealGlobal(self: *LocalQueue, target: *GlobalQueue) ?*Runnable {
        return self.buffer.stealUnbounded(target);
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

    const Pos = u8;
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
