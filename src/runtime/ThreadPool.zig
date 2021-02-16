const std = @import("std");
const assert = std.debug.assert;

const ThreadPool = @This();

max_threads: u16,
counter: u32 = 0,
futex: Futex = .{},
spawned: ?*Worker = null,
run_queues: [ScheduleHints.Priority.max]GlobalQueue = [_]GlobalQueue{.{}} ** ScheduleHints.Priority.max,

pub const InitConfig = struct {
    max_threads: ?u16 = null,
};

pub fn init(config: InitConfig) ThreadPool {
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

pub fn deinit(self: *ThreadPool) void {
    self.shutdownWorkers();
    self.joinWorkers();
    self.futex.deinit();
    self.* = undefined;
}

pub fn shutdown(self: *ThreadPool) void {
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

pub fn schedule(self: *ThreadPool, hints: ScheduleHints, batchable: anytype) void {
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
    ready: bool = false,
    waking: bool = false,
    notified: bool = false,
    shutdown: bool = false,

    fn pack(self: Counter) u32 {
        return ((@as(u32, @boolToInt(self.ready)) << 0) |
            (@as(u32, @boolToInt(self.waking)) << 1) |
            (@as(u32, @boolToInt(self.notified)) << 2) |
            (@as(u32, @boolToInt(self.shutdown)) << 3) |
            (@as(u32, @intCast(u14, self.idle)) << 4) |
            (@as(u32, @intCast(u14, self.spawned)) << 18));
    }

    fn unpack(value: u32) Counter {
        return .{
            .ready = (value & (1 << 0)) != 0,
            .waking = (value & (1 << 1)) != 0,
            .notified = (value & (1 << 2)) != 0,
            .shutdown = (value & (1 << 3)) != 0,
            .idle = @truncate(u14, value >> 4),
            .spawned = @truncate(u14, value >> 18),
        };
    }
};

fn notifyWorkers(self: *ThreadPool, _is_waking: bool) void {
    var attempts: usize = 5;
    var did_spawn = false;
    var is_waking = _is_waking;
    const max_threads = self.max_threads;
    var counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));

    while (true) {
        if (counter.shutdown) return;

        const wake_able = (counter.idle > 0) or (counter.spawned < max_threads) or did_spawn;
        const can_wake = (is_waking and attempts > 0) or (!is_waking and !counter.waking);
        if (wake_able and can_wake) {
            var new_counter = counter;
            new_counter.waking = true;
            if (counter.idle > 0) {
                new_counter.ready = true;
                new_counter.idle -= 1;
            } else if (!did_spawn) {
                new_counter.spawned += 1;
            }

            if (@cmpxchgWeak(
                u32,
                &self.counter,
                counter.pack(),
                new_counter.pack(),
                .Monotonic,
                .Monotonic,
            )) |updated| {
                spinLoopHint();
                counter = Counter.unpack(updated);
                continue;
            }

            if (counter.idle > 0) {
                self.futex.wake(@ptrCast(*const i32, &self.counter), 1);
                return;
            }

            did_spawn = true;
            if (Worker.spawn(self)) {
                return;
            }

            spinLoopHint();
            attempts -= 1;
            is_waking = true;
            counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));
            continue;
        }

        var new_counter = counter;
        new_counter.notified = true;
        if (is_waking) {
            new_counter.waking = false;
            if (did_spawn) new_counter.spawned -= 1;
        } else if (new_counter.notified) {
            return;
        }

        const updated = @cmpxchgWeak(
            u32,
            &self.counter,
            counter.pack(),
            new_counter.pack(),
            .Monotonic,
            .Monotonic,
        ) orelse return;
        counter = Counter.unpack(updated);
        spinLoopHint();
    }
}

fn suspendWorker(self: *ThreadPool, worker: *Worker) ?bool {
    var is_suspended = false;
    var is_waking = worker.is_waking;
    var counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));

    while (true) {
        if (counter.shutdown) break;

        var new_counter: ?Counter = null;
        if (counter.notified) {
            var new = counter;
            new.notified = false;
            new_counter = new;
        } else if (is_suspended and counter.ready) {
            var new = counter;
            new.ready = false;
            new_counter = new;
        } else if (!is_suspended) {
            var new = counter;
            if (is_waking) new.waking = false;
            new.idle += 1;
            new_counter = new;
        }

        if (new_counter) |new| {
            if (@cmpxchgWeak(
                u32,
                &self.counter,
                counter.pack(),
                new.pack(),
                .Monotonic,
                .Monotonic,
            )) |updated| {
                counter = Counter.unpack(updated);
                spinLoopHint();
                continue;
            } else if (counter.notified) {
                return is_waking;
            } else if (is_suspended and counter.ready) {
                return true;
            } else {
                counter = new;
                is_suspended = true;
            }
        }

        const expected = @bitCast(i32, counter.pack());
        self.futex.wait(@ptrCast(*const i32, &self.counter), expected);
        counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));
    }

    counter = Counter{ .spawned = 1 };
    counter = Counter.unpack(@atomicRmw(u32, &self.counter, .Sub, counter.pack(), .Monotonic));
    if (counter.spawned == 1) {
        self.futex.wake(@ptrCast(*const i32, &self.counter), 1);
    }

    while (true) {
        const thread = @atomicLoad(?*std.Thread, &worker.thread, .Monotonic) orelse return null;
        const thread_int = @ptrCast(*const i32, &thread).*;
        worker.run_queues[0].futex.wait(@ptrCast(*const i32, &worker.thread), thread_int);
    }
}

fn shutdownWorkers(self: *ThreadPool) void {
    var counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));
    while (!counter.shutdown) {
        var new_counter = counter;
        new_counter.idle = 0;
        new_counter.shutdown = true;

        if (@cmpxchgWeak(
            u32,
            &self.counter,
            counter.pack(),
            new_counter.pack(),
            .Monotonic,
            .Monotonic,
        )) |updated| {
            counter = Counter.unpack(updated);
            continue;
        }

        const waiters = @intCast(i32, counter.idle);
        if (waiters > 0) {
            self.futex.wake(@ptrCast(*const i32, &self.counter), waiters);
        }

        return;
    }
}

fn joinWorkers(self: *ThreadPool) void {
    while (true) {
        const counter = Counter.unpack(@atomicLoad(u32, &self.counter, .Monotonic));
        if (counter.spawned == 0) break;
        const current = @bitCast(i32, counter.pack());
        self.futex.wait(@ptrCast(*const i32, &self.counter), current);
    }

    var workers = @atomicLoad(?*Worker, &self.spawned, .Acquire);
    while (workers) |worker| {
        workers = worker.spawned_next;
        const thread = worker.thread orelse unreachable;
        @atomicStore(?*std.Thread, &worker.thread, null, .Monotonic);
        worker.run_queues[0].futex.wake(@ptrCast(*const i32, &worker.thread), 1);
        thread.wait();
    }
}

const Worker = struct {
    pool: *ThreadPool,
    thread: ?*std.Thread,
    spawned_next: ?*Worker = null,
    run_queues: [ScheduleHints.Priority.max]LocalQueue = [_]LocalQueue{.{}} ** ScheduleHints.Priority.max,
    xorshift: u32,
    is_waking: bool,

    fn spawn(pool: *ThreadPool) bool {
        const State = enum(i32) {
            empty,
            put,
            got,
        };

        const Spawner = struct {
            state: State = .empty,
            thread: *std.Thread = undefined,
            thread_pool: *ThreadPool,

            fn entry(self: *@This()) void {
                while (@atomicLoad(State, &self.state, .Acquire) != .put) {
                    std.os.sched_yield() catch {};
                }

                const thread = self.thread;
                const thread_pool = self.thread_pool;
                @atomicStore(State, &self.state, .got, .Release);

                var worker: Worker = undefined;
                worker.run(thread_pool, thread);
            }
        };

        var self = Spawner{ .thread_pool = pool };
        self.thread = std.Thread.spawn(&self, Spawner.entry) catch return false;
        @atomicStore(State, &self.state, .put, .Release);
        while (@atomicLoad(State, &self.state, .Acquire) != .got) {
            std.os.sched_yield() catch {};
        }

        return true;
    }

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
            assert(rc == 0);
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

    fn run(self: *Worker, pool: *ThreadPool, thread: *std.Thread) void {
        setCurrent(self);
        self.* = .{
            .pool = pool,
            .thread = thread,
            .xorshift = @truncate(u32, @ptrToInt(self) >> @sizeOf(usize)) | 1,
            .is_waking = true,
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
            if (self.poll()) |runnable| {
                if (self.is_waking) {
                    pool.notifyWorkers(true);
                    self.is_waking = false;
                }
                runnable.run();
                continue;
            } else if (pool.suspendWorker(self)) |is_waking| {
                self.is_waking = is_waking;
            } else {
                break;
            }
        }

        defer for (self.run_queues) |*queue| queue.deinit();
        while (true) {
            const thr = @atomicLoad(?*std.Thread, &self.thread, .Monotonic) orelse break;
            const current = @ptrCast(*const i32, &thr).*;
            self.run_queues[0].futex.wait(@ptrCast(*const i32, &self.thread), current);
        }
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
                break :blk (self.xorshift % num_threads);
            };

            var iter = skip + num_threads;
            var next_target: ?*Worker = null;
            while (iter > 0) : (iter -= 1) {
                const target = next_target orelse @atomicLoad(?*Worker, &self.pool.spawned, .Acquire).?;
                next_target = target.spawned_next;
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
        if (self == target and attempt > self.run_queues.len) {
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

    fn pollPool(self: *Worker, pool: *ThreadPool, attempt: usize) ?*Runnable {
        var queue: usize = 0;
        while (queue < std.math.min(attempt + 1, pool.run_queues.len)) : (queue += 1) {
            const our_queue = &self.run_queues[queue];
            const pool_queue = &pool.run_queues[queue];
            const first_runnable = pool_queue.pop() orelse continue;

            const head = first_runnable.next;
            var tail = head;
            while (tail) |runnable|
                tail = runnable.next orelse break;

            our_queue.push(.{
                .head = head,
                .tail = tail orelse undefined,
            });

            return first_runnable;
        }

        return null;
    }
};

const GlobalQueue = struct {
    head: ?*Runnable = null,

    fn push(self: *@This(), batch: Batch) void {
        if (batch.isEmpty()) {
            return;
        }

        var head = @atomicLoad(?*Runnable, &self.head, .Monotonic);
        while (true) {
            batch.tail.next = head;
            head = @cmpxchgWeak(
                ?*Runnable,
                &self.head,
                head,
                batch.head,
                .Release,
                .Monotonic,
            ) orelse return;
            spinLoopHint();
        }
    }

    fn pop(self: *@This()) ?*Runnable {
        var head = @atomicLoad(?*Runnable, &self.head, .Monotonic);
        while (true) {
            const runnable = head orelse return null;
            head = @cmpxchgWeak(
                ?*Runnable,
                &self.head,
                head,
                null,
                .Acquire,
                .Monotonic,
            ) orelse return runnable;
            spinLoopHint();
        }
    }
};

const LocalQueue = struct {
    head: u16 align(64) = 0,
    tail: u16 = 0,
    state: u32 = 0,
    futex: Futex = .{},
    queue: Batch = .{},
    buffer: [64]*Runnable = undefined,

    pub fn deinit(self: *@This()) void {
        self.futex.deinit();
        self.* = undefined;
    }
    
    const PRODUCER = 1 << 0; // the producer thread has/is requesting ownership of the queue
    const CONSUMER = 1 << 8; // a consumer thread has ownership of the queue
    const WAITING = 1 << 9; // the producer thread is blocked waiting for ownership of the queue
    const PENDING = 1 << 10; // the queue is not empty

    fn acquireProducer(self: *@This()) void {
        // Mark that a producer either owns the queue or is requesting ownership.
        @atomicStore(
            u8,
            @ptrCast(*u8, &self.state),
            PRODUCER,
            .Monotonic,
        );
        
        // Then, load the state to ensure theres no consumer.
        // Acquire barrier when loading as we need to see any changes the consumer made to the queue.
        var state = @atomicLoad(u32, &self.state, .Acquire);
        assert(state & PRODUCER != 0); // we set this bit earlier
        assert(state & WAITING == 0); // there should only be one producer

        // Wait for the consumer to complete finish up by polling the state.
        var adaptive_spin: usize = 0;
        while (true) {
            if (state & CONSUMER == 0) {
                return;
            }

            // Try to spin a little in the hopes that the consumer completes quickly.
            if (adaptive_spin < 100) {
                adaptive_spin += 1;
                spinLoopHint();
                state = @atomicLoad(u32, &self.state, .Acquire);
                continue;
            }

            // We need to ensure that it knows we're waiting so it can wake us up when it does.
            // Acquire on success as this needs to be stronger or equal to the failure ordering.
            // Release on success to ensure the consumer sees the self.event we setup when waking it.
            // Acquire on failure if the consumer completes and Releases changes to the queue while doing so.
            if (@cmpxchgWeak(
                u32,
                &self.state,
                state,
                state | WAITING,
                .AcqRel,
                .Acquire,
            )) |updated| {
                state = updated;
                spinLoopHint();
                continue;
            }

            self.futex.wait(@ptrCast(*const i32, &self.state), @bitCast(i32, state | WAITING));
            state = @atomicLoad(u32, &self.state, .Acquire);
        }
    }

    fn releaseProducer(self: *@This()) void {
        var new_state: u32 = undefined;
        if (self.queue.isEmpty()) {
            new_state = 0;
        } else {
            new_state = PENDING;
        }

        // Once we're done, release ownership and mark the queue as empty or not.
        // Release barrier to ensure stealer threads see the self.queue changes we made via Acquire.
        @atomicStore(u32, &self.state, new_state, .Release);
    }

    fn tryAcquireConsumer(self: *@This(), is_producer: bool) ?bool {
        var state = @atomicLoad(u32, &self.state, .Monotonic);
        while (true) {
            if (state & (PENDING | CONSUMER | PRODUCER) != PENDING) {
                return null;
            }

            state = @cmpxchgWeak(
                u32,
                &self.state,
                state,
                state | CONSUMER,
                .Acquire,
                .Monotonic,
            ) orelse return true;

            if (!is_producer) {
                return false;
            } else {
                spinLoopHint();
            }
        }
    }

    fn releaseConsumer(self: *@This(), is_producer: bool) void {
        if (is_producer) {
            return self.releaseProducer();
        }

        var remove: u32 = CONSUMER;
        if (self.queue.isEmpty()) {
            remove |= PENDING;
        }

        const state = @atomicRmw(u32, &self.state, .Sub, remove, .AcqRel);
        if (state & WAITING != 0) {
            self.futex.wake(@ptrCast(*const i32, &self.state), 1);
        }
    }

    pub fn push(self: *@This(), _batch: Batch) void {
        var batch = _batch;
        if (batch.isEmpty()) {
            return;
        }

        var tail = self.tail;
        var head = @atomicLoad(u16, &self.head, .Monotonic);
        while (true) {
            if (batch.isEmpty()) {
                return;
            }

            if (tail -% head < self.buffer.len) {
                while (tail -% head < self.buffer.len) {
                    const runnable = batch.popFront() orelse break;
                    @atomicStore(*Runnable, &self.buffer[tail % self.buffer.len], runnable, .Unordered);
                    tail +%= 1;
                }

                @atomicStore(u16, &self.tail, tail, .Release);
                head = @atomicLoad(u16, &self.head, .Monotonic);
                continue;
            }

            _ = self.acquireProducer();
            defer self.releaseProducer();

            self.queue.pushBack(batch);
            return;
        }
    }

    pub fn pop(self: *@This()) ?*Runnable {
        var tail = self.tail;
        var head = @atomicLoad(u16, &self.head, .Monotonic);
        while (tail != head) {
            head = @cmpxchgWeak(
                u16,
                &self.head,
                head,
                head +% 1,
                .Monotonic,
                .Monotonic,
            ) orelse return self.buffer[head % self.buffer.len];
        }

        var new_tail = tail;
        defer if (new_tail != tail) {
            @atomicStore(u16, &self.tail, new_tail, .Release);
        };

        const acquired = self.tryAcquireConsumer(true) orelse false;
        if (!acquired) return null;
        defer self.releaseConsumer(true);            

        const runnable = self.queue.popFront();
        while (new_tail -% head < self.buffer.len) {
            const extra = self.queue.popFront() orelse break;
            @atomicStore(*Runnable, &self.buffer[new_tail % self.buffer.len], extra, .Unordered);
            new_tail +%= 1;
        }

        return runnable;
    }

    pub fn popAndSteal(self: *@This(), target: *@This()) ?*Runnable {
        // Make sure we only steal from queues that aren't ourselves.
        if (self == target) {
            return self.pop();
        }

        // Make sure that our queue is empty before stealing others.
        var tail = self.tail;
        var head = @atomicLoad(u16, &self.head, .Monotonic);
        var state = @atomicLoad(u32, &self.state, .Unordered);
        if ((tail != head) or (state & PENDING != 0)) {
            return self.pop();
        }

        var target_head = @atomicLoad(u16, &target.head, .Monotonic);
        while (true) {
            const target_tail = @atomicLoad(u16, &target.tail, .Acquire);

            var take = target_tail -% target_head;
            if (take == 0) {
                const acquired = target.tryAcquireConsumer(false) orelse return null;
                if (acquired) {
                    break;
                } else {
                    target_head = @atomicLoad(u16, &target.head, .Monotonic);
                    continue;
                }
            }

            take = take - (take / 2);
            if (take > target.buffer.len / 2) {
                spinLoopHint();
                target_head = @atomicLoad(u16, &target.head, .Monotonic);
                continue;
            }

            const runnable = @atomicLoad(*Runnable, &target.buffer[target_head % target.buffer.len], .Unordered);
            var new_target_head = target_head +% 1;
            var new_tail = tail;
            take -= 1;

            while (take > 0) : (take -= 1) {
                const stolen = @atomicLoad(*Runnable, &target.buffer[new_target_head % target.buffer.len], .Unordered);
                new_target_head +%= 1;
                @atomicStore(*Runnable, &self.buffer[new_tail % self.buffer.len], stolen, .Unordered);
                new_tail +%= 1;
            }

            if (@cmpxchgWeak(
                u16,
                &target.head,
                target_head,
                new_target_head,
                .AcqRel,
                .Monotonic,
            )) |updated| {
                target_head = updated;
                continue;
            }

            if (new_tail != tail) {
                @atomicStore(u16, &self.tail, new_tail, .Release);
            }
            return runnable;         
        }

        // Pop the first runnable as we'll be returning this one as stolen
        const runnable = target.queue.popFront() orelse unreachable;

        var new_tail = tail;
        while (new_tail -% head < self.buffer.len) {
            const stolen = target.queue.popFront() orelse break;
            @atomicStore(*Runnable, &self.buffer[new_tail % self.buffer.len], stolen, .Unordered);
            new_tail +%= 1;
        }

        if (new_tail != tail) {
            @atomicStore(u16, &self.tail, new_tail, .Release);
        }

        target.releaseConsumer(false);
        return runnable;
    }
};

const Futex = if (std.builtin.os.tag == .windows)
    WindowsFutex
else if (std.builtin.os.tag == .linux)
    LinuxFutex
else if (std.builtin.link_libc)
    PosixFutex
else
    SpinFutex;

const WindowsFutex = struct {
    lock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,
    cond: std.os.windows.CONDITION_VARIABLE = std.os.windows.CONDITION_VARIABLE_INIT,

    pub fn deinit(self: *@This()) void {
        // no-op
    }

    pub fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.lock);
        defer std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.lock);

        while (@atomicLoad(i32, ptr, .Acquire) == cmp) {
            _ = std.os.windows.kernel32.SleepConditionVariableSRW(
                &self.cond,
                &self.lock,
                std.os.windows.INFINITE,
                0,
            );
        }
    }

    pub fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        switch (waiters) {
            0 => {},
            1 => std.os.windows.kernel32.WakeConditionVariable(&self.cond),
            else => std.os.windows.kernel32.WakeAllConditionVariable(&self.cond),
        }
    }
};

const LinuxFutex = struct {
    pub fn deinit(self: *@This()) void {
        // no-op
    }

    pub fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        switch (std.os.linux.getErrno(std.os.linux.futex_wait(
            ptr,
            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAIT,
            cmp,
            null,
        ))) {
            0 => {},
            std.os.EINTR => {},
            std.os.EAGAIN => {},
            else => unreachable,
        }
    }

    pub fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        switch (std.os.linux.getErrno(std.os.linux.futex_wake(
            ptr,
            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAKE,
            waiters,
        ))) {
            0 => {},
            std.os.EFAULT => {},
            else => unreachable,
        }
    }
};

const PosixFutex = struct {
    cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn deinit(self: *@This()) void {
        _ = std.c.pthread_cond_destroy(&self.cond);
        _ = std.c.pthread_mutex_destroy(&self.mutex);
    }

    pub fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

        while (@atomicLoad(i32, ptr, .Acquire) == cmp) {
            assert(std.c.pthread_cond_wait(&self.cond, &self.mutex) == 0);
        }
    }

    pub fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        switch (waiters) {
            0 => {},
            1 => assert(std.c.pthread_cond_signal(&self.cond) == 0),
            else => assert(std.c.pthread_cond_broadcast(&self.cond) == 0),
        }
    }
};

const SpinFutex = struct {
    pub fn deinit(self: *@This()) void {
        // no-op
    }

    pub fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        while (@atomicLoad(i32, ptr, .Acquire) == cmp) {
            spinLoopHint();
        }
    }

    pub fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        // no-op
    }
};

fn spinLoopHint() void {
    asm volatile (switch (std.builtin.arch) {
            .i386, .x86_64 => "pause",
            .aarch64 => "yield",
            else => "",
        });
}
