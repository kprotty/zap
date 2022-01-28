
const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;
const Futex = std.Thread.Futex;

const ThreadPool = @This();

options: u32,
state: Atomic(u32) = Atomic(u32).init(0),
idle_semaphore: Semaphore = .{},
join_event: Event = .{},
injector: Queue = .{},
workers: ?[*]Atomic(?*Worker) = null,

const Options = packed struct {
    co_prime: u8,
    max_workers: u8,
    stack_blocks: u16,
};

pub const Config = struct {
    max_threads: u8,
    stack_size: u32 = (std.Thread.SpawnConfig{}).stack_size,
};

pub fn init(config: Config) ThreadPool {
    return .{
        .options = @bitCast(u32, Options{
            .co_prime = 0,
            .max_workers = config.max_threads,
            .stack_blocks = @intCast(u16, config.stack_size / (64 * 1024)),
        }),
    };
}

pub const Runnable = struct {
    next: ?*Runnable = null,
    runFn: fn (*Runnable) void,
};

pub const Batch = struct {
    head: ?*Runnable = null,
    tail: ?*Runnable = null,

    pub fn from(runnable: *Runnable) Batch {
        runnable.next = null;
        return .{
            .head = runnable,
            .tail = runnable,
        };
    }

    pub fn push(self: *Batch, batch: Batch) void {
        const prev = if (self.tail) |tail| &tail.next else &self.head;
        prev.* = batch.head orelse return;
        self.tail = batch.tail orelse unreachable;
    }

    pub fn pop(self: *Batch) ?*Runnable {
        const runnable = self.head orelse return null;
        self.head = runnable.next;
        if (self.head == null) self.tail = null;
        return runnable;
    }
};

pub fn schedule(self: *ThreadPool, batch: Batch) void {
    if (batch.head == null) return;
    if (batch.tail == null) unreachable;

    if (Worker.tls_current) |worker| {
        if (worker.thread_pool == self) {
            worker.push(batch);
            self.notify();
            return;
        }
    }

    self.injector.push(batch, .multi_producer);
    std.atomic.fence(.SeqCst);
    self.notify();
}

const State = packed struct {
    idle: u8 = 0,
    spawned: u8 = 0,
    searching: u8 = 0,
    terminating: u8 = 0,
};

fn notify(self: *ThreadPool) void {
    const options = @bitCast(Options, self.options);
    var state = @bitCast(State, self.state.load(.Monotonic));

    while (true) {
        assert(state.idle <= options.max_workers);
        assert(state.spawned <= options.max_workers);
        assert(state.searching <= options.max_workers);
        
        var new_state = state;
        if (state.terminating != 0) {
            return;
        }

        new_state.searching = 1;
        if (state.searching > 0) {
            return;
        }

        if (std.math.sub(u8, state.idle, 1) catch null) |new_idle| {
            new_state.idle = new_idle;
        } else if (state.spawned < options.max_workers) {
            new_state.spawned += 1;
        } else {
            return;
        }

        state = @bitCast(State, self.state.tryCompareAndSwap(
            @bitCast(u32, state),
            @bitCast(u32, new_state),
            .Release,
            .Monotonic,
        ) orelse {
            if (state.idle > 0) {
                self.idle_semaphore.post(1);
                return;
            }

            const worker_id = state.spawned;
            assert(worker_id < options.max_workers);

            const stack_size = @as(u32, options.stack_blocks) * (64 * 1024);
            const thread = std.Thread.spawn(
                .{ .stack_size = stack_size },
                ThreadPool.run,
                .{ self, worker_id },
            ) catch return self.complete(true);

            thread.detach();
            return;
        });
    }
}

fn search(self: *ThreadPool) bool {
    const one_searching = @bitCast(u32, State{ .searching = 1 });
    const options = @bitCast(Options, self.options);
    const state = @bitCast(State, self.state.load(.Monotonic));

    assert(state.searching <= options.max_workers);
    if (2 * @as(u32, state.searching) >= @as(u32, options.max_workers)) {
        return false;
    }

    const new_state = @bitCast(State, self.state.fetchAdd(one_searching, .Acquire));
    assert(new_state.searching < options.max_workers);
    return true;
}

fn discovered(self: *ThreadPool) void {
    const one_searching = @bitCast(u32, State{ .searching = 1 });
    const options = @bitCast(Options, self.options);
    const state = @bitCast(State, self.state.fetchSub(one_searching, .Release));

    assert(state.searching <= options.max_workers);
    assert(state.searching > 0);
    if (state.searching == 1) {
        self.notify();
    }
}

fn wait(self: *ThreadPool, was_searching: bool) error{Shutdown}!void {
    const one_idle = @bitCast(u32, State{ .idle = 1 });
    const one_searching = @bitCast(u32, State{ .searching = 1 });
    const update = one_idle -% (one_searching * @boolToInt(was_searching));

    const options = @bitCast(Options, self.options);
    const state = @bitCast(State, self.state.fetchAdd(update, .SeqCst));

    assert(state.idle < options.max_workers);
    assert(state.searching <= options.max_workers);
    assert(state.searching >= @boolToInt(was_searching));

    if (state.terminating != 0) {
        const new_state = @bitCast(State, self.state.fetchSub(one_idle, .Monotonic));
        assert(new_state.idle <= options.max_workers);
        assert(new_state.idle > 0);
        return error.Shutdown;
    }

    if (was_searching and state.searching == 1 and !self.injector.isEmpty()) {
        self.notify();
    }

    self.idle_semaphore.wait();
}

fn complete(self: *ThreadPool, was_searching: bool) void {
    const one_spawned = @bitCast(u32, State{ .spawned = 1 });
    const one_searching = @bitCast(u32, State{ .searching = 1 });
    const remove = one_spawned +% (one_searching * @boolToInt(was_searching));

    const options = @bitCast(Options, self.options);
    const state = @bitCast(State, self.state.fetchSub(remove, .AcqRel));
    
    assert(state.idle <= options.max_workers);
    assert(state.searching <= options.max_workers);
    assert(state.searching >= @boolToInt(was_searching));

    assert(state.spawned <= options.max_workers);
    assert(state.spawned > 0);
    if (state.spawned == 1 and state.terminating != 0) {
        self.join_event.set();
    }
}

pub fn shutdown(self: *ThreadPool) void {
    const options = @bitCast(Options, self.options);
    var state = @bitCast(State, self.state.load(.Monotonic));

    while (true) {
        assert(state.idle <= options.max_workers);
        assert(state.spawned <= options.max_workers);
        assert(state.searching <= options.max_workers);

        var new_state = state;
        new_state.terminating = 1;
        if (state.terminating != 0) {
            return;
        }

        new_state.idle = 0;
        new_state.searching += state.idle;
        assert(new_state.searching <= options.max_workers);

        state = @bitCast(State, self.state.tryCompareAndSwap(
            @bitCast(u32, state),
            @bitCast(u32, new_state),
            .Release,
            .Monotonic,
        ) orelse {
            if (state.idle > 0) self.idle_semaphore.post(state.idle);
            return;
        });
    }
}

pub fn join(self: *ThreadPool) void {
    const options = @bitCast(Options, self.options);
    var state = @bitCast(State, self.state.load(.Acquire));
    
    assert(state.idle <= options.max_workers);
    assert(state.spawned <= options.max_workers);
    assert(state.searching <= options.max_workers);

    if (state.spawned > 0) {
        self.join_event.wait();
        state = @bitCast(State, self.state.load(.Acquire));
    }

    assert(state.idle == 0);
    assert(state.spawned == 0);
    assert(state.searching == 0);

    const workers = self.workers orelse return;
    const first_worker = workers[0].load(.Acquire) orelse return;
    first_worker.shutdown_event.set();
}

fn run(self: *ThreadPool, worker_id: u8) void {
    var options = @bitCast(Options, self.options);
    assert(worker_id < options.max_workers);

    var stack_workers: [std.math.maxInt(u8)]Atomic(?*Worker) = undefined;
    if (worker_id == 0) {
        const workers = stack_workers[0..options.max_workers];
        for (workers) |*w| w.* = Atomic(?*Worker).init(null);
        assert(self.workers == null);
        self.workers = workers.ptr;

        assert(options.co_prime == 0);
        options.co_prime = Random.co_prime(options.max_workers);
        self.options = @bitCast(u32, options);
    }
    
    var worker = Worker{ .thread_pool = self };
    Worker.tls_current = &worker;

    const workers = (self.workers orelse unreachable)[0..options.max_workers];
    assert(workers[worker_id].loadUnchecked() == null);
    workers[worker_id].store(&worker, .Release);

    if (std.math.sub(u8, worker_id, 1) catch null) |prev_id| {
        const prev_worker = workers[prev_id].load(.Acquire) orelse unreachable;
        prev_worker.shutdown_next = &worker;
    }
    
    defer shutdown: {
        worker.shutdown_event.wait();
        const next_worker = worker.shutdown_next orelse break :shutdown;
        next_worker.shutdown_event.set();
    }

    var rng = Random.Generator.init(worker_id);
    var is_searching = true;
    defer self.complete(is_searching);

    while (true) {
        const popped = worker.pop() orelse steal: {
            if (!is_searching) is_searching = self.search();
            if (is_searching) {
                var attempts: u8 = 32;
                while (attempts > 0) : (attempts -= 1) {
                    var was_contended = false;
                    var stole: ?*Runnable = null;
                    var seq = Random.Sequence.init(options.max_workers, options.co_prime, &rng);

                    while (seq.next()) |steal_id| {
                        const target = workers[steal_id].load(.Acquire) orelse continue;
                        stole = worker.steal(target) catch |err| {
                            if (err == error.Contended) was_contended = true;
                            continue;
                        };
                    }

                    if (stole == null) blk: {
                        stole = worker.steal(&self.injector) catch |err| {
                            if (err == error.Contended) was_contended = true;
                            break :blk;
                        };
                    }

                    if (stole) |runnable| break :steal runnable;
                    if (!was_contended) break;
                    std.atomic.spinLoopHint(); 
                }
            }

            break :steal null;
        };

        const was_searching = is_searching;
        is_searching = false;

        if (popped) |runnable| {
            if (was_searching) self.discovered();
            (runnable.runFn)(runnable);
            continue;
        }

        self.wait(was_searching) catch break;
        is_searching = true;
    }
}

const Worker = struct {
    thread_pool: *ThreadPool,
    shutdown_next: ?*Worker = null,
    shutdown_event: Event = .{},
    overflow_queue: Queue = .{},
    buffer: Buffer = .{},

    threadlocal var tls_current: ?*Worker = null;

    fn push(self: *Worker, batch: Batch) void {
        const runnable = batch.head orelse return;
        if (@as(?*Runnable, runnable) == batch.tail) {
            self.buffer.pushOverflow(runnable, &self.overflow_queue);
            return;
        }

        var mut_batch = batch;
        self.buffer.push(&mut_batch);
        self.overflow_queue.push(mut_batch, .single_producer);
    }

    fn pop(self: *Worker) ?*Runnable {
        return self.buffer.pop() orelse {
            return self.steal(&self.overflow_queue) catch null;
        };
    }

    fn steal(self: *Worker, target: anytype) error{Empty, Contended}!*Runnable {
        if (@TypeOf(target) == *Queue) {
            var consumer = try target.consume();
            defer consumer.release();

            const runnable = consumer.pop() orelse return error.Empty;
            self.buffer.push(&consumer);
            return runnable;
        }

        comptime assert(@TypeOf(target) == *Worker);
        return self.steal(&target.overflow_queue) catch |err| {
            return target.buffer.steal() catch |e| switch (e) {
                error.Empty => err,
                error.Contended => error.Contended,
            };
        };
    }
};

const Random = struct {
    fn gcd(a: u8, b: u8) u8 {
        var x = [_]u8{ a, b };
        while (true) {
            if (x[0] == x[1]) return x[0];
            const cmp = x[0] > x[1];
            x[@boolToInt(!cmp)] -= x[@boolToInt(cmp)];
        }
    }

    fn co_prime(n: u8) u8 {
        assert(n != 0);
        var prime = n / 2;
        while (prime < n) : (prime += 1) {
            if (gcd(prime, n) == 1)
                return prime;
        }
        return 1;
    }

    const Generator = struct {
        xorshift: u32,

        fn init(seed: u8) Generator {
            return .{ .xorshift = (@as(u32, seed) << 1) | 1 };
        }

        fn next(self: *Generator) u32 {
            self.xorshift ^= self.xorshift << 13;
            self.xorshift ^= self.xorshift >> 17;
            self.xorshift ^= self.xorshift << 5;
            assert(self.xorshift != 0);
            return self.xorshift;
        }
    };

    const Sequence = struct {
        iter: u8,
        range: u8,
        prime: u8,
        index: u32,

        fn init(range: u8, prime: u8, generator: *Generator) Sequence {
            return .{
                .iter = range,
                .range = range,
                .prime = prime,
                .index = generator.next() % @as(u32, range),
            };
        }

        fn next(self: *Sequence) ?u8 {
            defer {
                self.index += self.prime;
                self.index -= self.range * @boolToInt(self.index >= @as(u32, self.range));
            }

            self.iter = std.math.sub(u8, self.iter, 1) catch return null;
            assert(self.index < @as(u32, self.range));
            return @intCast(u8, self.index);
        }
    };
};

const Queue = struct {
    pushed: Atomic(?*Runnable) = Atomic(?*Runnable).init(null),
    popped: Atomic(?*Runnable) = Atomic(?*Runnable).init(null),

    fn isEmpty(self: *const Queue) bool {
        const pushed = self.pushed.load(.Acquire);
        const popped = self.popped.load(.Acquire);
        return (pushed orelse popped) == null;
    }

    const Producer = enum {
        single_producer,
        multi_producer,
    };

    fn push(self: *Queue, batch: Batch, producer: Producer) void {
        const head = batch.head orelse return;
        const tail = batch.tail orelse unreachable;

        var pushed = self.pushed.load(.Monotonic);
        while (true) {
            tail.next = pushed;

            if (pushed == null and producer == .single_producer) {
                self.pushed.store(head, .Release);
                return;
            }

            pushed = self.pushed.tryCompareAndSwap(
                pushed,
                head,
                .Release,
                .Monotonic,
            ) orelse break;
        }
    }

    var is_consuming: Runnable = undefined;

    fn consume(self: *Queue) error{Empty, Contended}!Consumer {
        var popped = self.popped.load(.Monotonic);
        while (true) {
            if (popped == null and self.pushed.load(.Monotonic) == null)
                return error.Empty;
            if (popped == @as(?*Runnable, &is_consuming))
                return error.Contended;

            popped = self.popped.tryCompareAndSwap(
                popped,
                &is_consuming,
                .Acquire,
                .Monotonic,
            ) orelse return Consumer{
                .queue = self,
                .popped = popped,
            };
        } 
    }

    const Consumer = struct {
        queue: *Queue,
        popped: ?*Runnable,

        fn pop(self: *Consumer) ?*Runnable {
            const runnable = self.popped orelse self.queue.pushed.swap(null, .Acquire) orelse return null;
            self.popped = runnable.next;
            return runnable;
        }

        fn release(self: Consumer) void {
            assert(self.popped != @as(?*Runnable, &is_consuming));
            self.queue.popped.store(self.popped, .Release);
        }
    };
};

const Buffer = struct {
    head: Atomic(usize) = Atomic(usize).init(0),
    tail: Atomic(usize) = Atomic(usize).init(0),
    array: @TypeOf(array_init) = array_init,

    const capacity = 256;
    const slot_init = Atomic(?*Runnable).init(null);
    const array_init = [_]@TypeOf(slot_init){slot_init} ** capacity;

    fn push(self: *Buffer, batch: anytype) void {
        const head = self.head.load(.Monotonic);
        const tail = self.tail.loadUnchecked();

        const size = tail -% head;
        assert(size <= capacity);

        var new_tail = tail;
        defer if (new_tail != tail)
            self.tail.store(new_tail, .Release);

        var free_slots = capacity - size;
        while (free_slots > 0) : (free_slots -= 1) {
            const runnable = batch.pop() orelse break;
            runnable.next = self.array[(new_tail -% 1) % capacity].loadUnchecked();
            self.array[new_tail % capacity].store(runnable, .Unordered);
            new_tail +%= 1;
        }
    }

    fn pushOverflow(self: *Buffer, runnable: *Runnable, overflow_queue: *Queue) void {
        const head = self.head.load(.Monotonic);
        const tail = self.tail.loadUnchecked();

        const size = tail -% head;
        assert(size <= capacity);

        if (size == capacity) {
            const migrate = size / 2;
            const new_head = self.head.compareAndSwap(
                head,
                head +% migrate,
                .Acquire,
                .Monotonic,
            ) orelse {
                const first = self.array[(head +% (migrate - 1)) % capacity].loadUnchecked() orelse unreachable;
                const last = self.array[head % capacity].loadUnchecked() orelse unreachable;
                last.next = null;

                var overflowed = Batch.from(runnable);
                overflowed.push(.{ .head = first, .tail = last });
                overflow_queue.push(overflowed, .single_producer);
                return;
            };

            const new_size = tail -% new_head;
            assert(new_size < capacity);
        }

        runnable.next = self.array[(tail -% 1) % capacity].loadUnchecked();
        self.array[tail % capacity].store(runnable, .Unordered);
    }

    fn pop(self: *Buffer) ?*Runnable {
        const tail = self.tail.loadUnchecked();
        const new_tail = tail -% 1;

        self.tail.store(new_tail, .SeqCst);
        const head = self.head.load(.SeqCst);

        const size = tail -% head;
        assert(size <= capacity);

        const runnable = self.array[new_tail % capacity].loadUnchecked();
        if (size >= 1) {
            return (runnable orelse unreachable);
        }

        self.tail.store(tail, .Monotonic);
        if (size == 1) {
            _ = self.head.compareAndSwap(
                head,
                tail,
                .Acquire,
                .Monotonic,
            ) orelse return (runnable orelse unreachable);
        }

        return null;
    }

    fn steal(self: *Buffer) error{Empty, Contended}!*Runnable {
        const head = self.head.load(.Acquire);
        const tail = self.tail.load(.Acquire);
        if (head == tail or head == (tail +% 1)) {
            return error.Empty;
        }

        const runnable = self.array[head % capacity].load(.Unordered);
        _ = self.head.compareAndSwap(
            head,
            head +% 1,
            .AcqRel,
            .Monotonic,
        ) orelse return (runnable orelse unreachable);

        return error.Contended;
    }
};

const Event = struct {
    state: Atomic(u32) = Atomic(u32).init(unset),

    const unset = 0;
    const waiting = 1;
    const is_set = 2;

    fn wait(self: *Event) void {
        var state = self.state.load(.Acquire);
        defer assert(state == is_set);
        
        if (state == unset) {
            state = self.state.compareAndSwap(
                unset,
                waiting,
                .Acquire,
                .Acquire,
            ) orelse waiting;
        }

        while (state == waiting) {
            Futex.wait(&self.state, waiting, null) catch unreachable;
            state = self.state.load(.Acquire);
        }
    }

    fn set(self: *Event) void {
        switch (self.state.swap(is_set, .Release)) {
            waiting => Futex.wake(&self.state, std.math.maxInt(u32)),
            unset, is_set => {},
            else => unreachable,
        }
    }
};

const Semaphore = struct {
    value: Atomic(i32) = Atomic(i32).init(0),
    count: Atomic(u32) = Atomic(u32).init(0),

    fn wait(self: *Semaphore) void {
        const value = self.value.fetchSub(1, .Acquire);
        assert(value > std.math.minInt(i32));
        if (value > 0) {
            return;
        }

        while (true) : (Futex.wait(&self.count, 0, null) catch unreachable) {
            var count = self.count.load(.Monotonic);
            while (std.math.sub(u32, count, 1) catch null) |new_count| {
                count = self.count.tryCompareAndSwap(
                    count,
                    new_count,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
            }
        }
    }

    fn post(self: *Semaphore, n: u31) void {
        const value = self.value.fetchAdd(@as(i32, n), .Release);
        assert(value <= std.math.maxInt(i32) - @as(i32, n));
        if (value >= 0) {
            return;
        }

        const to_wake = @intCast(u32, std.math.min(-value, @as(i32, n)));
        const count = self.count.fetchAdd(to_wake, .Release);
        assert(count <= std.math.maxInt(u32) - to_wake);
        Futex.wake(&self.count, to_wake);
    }
};