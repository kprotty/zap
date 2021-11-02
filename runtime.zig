

const Loop = struct {
    workers: []Worker,
    pool: Thread.Pool,
    started: Timer.Instant,
    idle: Atomic(usize) = Atomic(usize).init(0),
    injected: Atomic(usize) = Atomic(usize).init(0),
    searching: Atomic(usize) = Atomic(usize).init(0),

    fn nanotime(self: *Loop) u64 {
        const instant = Timer.Instant.now();
        return instant.since(self.started)
    }

    fn schedule(self: *Loop, task: *Task) void {
        const thread = Thread.current orelse @panic("scheduling task outside of the runtime");
        const worker_index = thread.worker_index orelse return self.inject(Task.List.from(task));
        const worker = &self.workers[worker_index];

        worker.run_queue.push(task);
        self.notify(); 
    }

    fn inject(self: *Loop, list: Task.List) void {
        const injected = self.injected.fetchAdd(1, .Monotonic);
        const worker = &self.workers[injected % self.workers.len];
        
        worker.run_queue.inject(list);
        std.atomic.fence(.SeqCst);
        self.notify();
    }

    fn notify(self: *Loop) void {
        if (self.peekIdleWorker() == null)
            return;

        const searching = self.searching.load(.Monotonic);
        assert(searching <= self.workers.len);
        if (searching > 0)
            return;

        if (self.searching.compareAndSwap(0, 1, .SeqCst, .Monotonic)) |_searching| {
            assert(_searching <= self.workers.len);
            return;
        }

        if (self.popIdleWorker()) |worker_index| blk: {
            return self.pool.notify(.{
                .worker_index = worker_index,
                .searching = true,
            }) catch {
                self.pushIdleWorker(worker_index);
                break :blk;
            };
        }

        const searching = self.searching.fetchSub(1, .SeqCst);
        assert(searching <= self.workers.len);
        assert(searching > 0);
    }

    fn startSearching(self: *Loop) bool {
        var searching = self.searching.load(.Monotonic);
        assert(searching <= self.workers.len);

        if ((2 * searching) >= self.workers.len)
            return false;
        
        searching = self.searching.fetchAdd(1, .SeqCst);
        assert(searching < self.workers.len);
        return true;
    }

    fn stopSearching(self: *Loop, worker_index: usize) bool {
        assert(worker_index < self.workers.len);
        self.pushIdleWorker(worker_index);

        const searching = self.searching.fetchSub(1, .SeqCst);
        assert(searching <= self.workers.len);
        assert(searching > 0);

        return searching == 1;
    }

    fn retrySearching(self: *Loop) ?usize {
        const worker_index = self.popIdleWorker() orelse return null;

        searching = self.searching.fetchAdd(1, .SeqCst);
        assert(searching < self.workers.len);

        return worker_index;
    }

    fn hasPendingTasks(self: *const Loop) bool {
        for (self.workers) |*worker| {
            if (worker.run_queue.hasPending())
                return true;
        }
        return false;
    }

    fn pushIdleWorker(self: *Loop, worker_index: usize) void {

    }

    fn peekIdleWorker(self: *const Loop) ?usize {

    }

    fn popIdleWorker(self: *Loop) ?usize {

    }
};

const Thread = struct {
    loop: *Loop,
    worker_index: ?usize = null,

    threadlocal var current: ?*Thread = null;

    const Instance = struct {
        thread: *Thread,
        tick: usize,
        is_searching: bool,
        rng: Random.Generator,

        fn poll(self: *Instance, thread: *Thread) ?*Task {
            const loop = thread.loop;
            while (true) {
                if (thread.worker_index) |worker_index| {
                    if (self.pop(thread, loop, worker_index)) |task|
                        return task;

                    if (self.is_searching) {
                        thread.worker_index = null;
                        self.is_searching = false;
                        const was_last = loop.stopSearching(worker_index);

                        if (was_last and loop.hasPendingTasks()) blk: {
                            thread.worker_index = loop.retrySearching() orelse break :blk;
                            self.is_searching = true;
                            continue;
                        }
                    }
                }

                var polled = loop.io_driver.poll(null);
                if (polled.head != null) {
                    const worker_index = loop.retrySearching() orelse {
                        loop.inject(polled);
                        continue;
                    };

                    thread.worker_index = worker_index;
                    self.is_searching = true;

                    const task = polled.pop() orelse unreachable;
                    if (polled.head != null) {
                        loop.workers[worker_index].run_queue.fill(&polled);
                        loop.notify();
                    }
                    return task;
                }

                const notified = loop.pool.wait(null) catch |err| switch (err) {
                    error.TimedOut => continue,
                    error.Shutdown => return null,
                };

                thread.worker_index = notified.worker_index;
                self.is_searching = notified.is_searching;
            }
        }

        fn pop(self: *Instance, thread: *Thread, loop: *Loop, worker_index: usize) ?*Task {
            const worker = &loop.workers[worker_index];
            const run_queue = &worker.run_queue;

            const be_fair = self.tick % 61 == 0;
            if (run_queue.pop(be_fair)) |task|
                return task;

            var polled = loop.io_driver.poll(0);
            if (polled.pop()) |task| {
                if (polled.head != null) {
                    run_queue.fill(&polled);
                    loop.notify();
                }
                return task;
            }

            if (!self.is_searching)
                self.is_searching = loop.startSearching();

            if (self.is_searching) {
                var attempts: usize = 32;
                while (attempts > 0) : (attempts -= 1) {
                    var was_contended = false;
                    var iter = self.rng.iter(loop.rng_seq);

                    while (iter.next()) |steal_index| {
                        const target_queue = &loop.workers[steal_index].run_queue;
                        return run_queue.steal(target_queue) catch |err| switch (err) {
                            if (err == error.Contended) was_contended = true;
                            continue;
                        };
                    }

                    switch (was_contended) {
                        true => std.atomic.spinLoopHint(),
                        else => break,
                    }
                }
            }

            return null;
        }
    };

    const Pool = struct {
        lock: Lock = .{},
        shutdown: bool = false,
        idle: ?*Waiter = null,
        joiner: ?*Signal = null,

        const Notified = struct {
            worker_index: usize,
            searching: bool,
        };

        fn notify(self: *Pool, notified: Notified) SpawnError!void {

        }

        fn wait(self: *Pool, deadline: ?u64)
    };
};

const Random = struct {
    const SeqGen = struct {
        range: usize,
        prime: usize,

        fn from(range: usize) SeqGen {
            var prime = range - 1;
            while (prime >= (range / 2) and gcd(prime, range) != 1)
                prime -= 1;
            return .{ .range = range, .prime = prime };
        }

        fn gcd(a: usize, b: usize) usize {
            var u = a;
            var v = b;
            if (u == 0) return v;
            if (v == 0) return u;
            const shift = @ctz(usize, u | v);
            u >>= @ctz(usize, u);
            while (true) {
                v >>= @ctz(usize, v);
                if (u > v) std.mem.swap(usize, &u, &v);
                v -= u;
                if (v == 0) return u << shift;
            }
        }
    };
    
    const Generator = struct {
        fn init(seed: usize) Generator {
            var xs = seed *% @truncate(usize, 0x9E3779B97F4A7C15);
            if (xs == 0) xs = 0xdeadbeef;
            return .{ .xorshift = xs };
        }

        fn next(self: *Generator) usize {
            const shifts = switch (@sizeOf(usize)) {
                8 => .{ 13, 7, 17 },
                4 => .{ 13, 17, 5 },
                else => @compileError("architecture unsupported"),
            };

            var xs = self.xorshift;
            xs ^= xs << shifts[0];
            xs ^= xs >> shifts[1];
            xs ^= xs << shifts[2];
            self.xorshift = xs;
            return xs;
        }

        fn iter(self: *Generator, seq_gen: SeqGen) Iter {
            return .{
                .seq_gen = seq_gen,
                .offset = self.next() % seq_gen.range,
                .index = seq_gen.range,
            };
        }
    };

    const Iterator = struct {
        seq_gen: SeqGen,
        offset: usize,
        index: usize = 0,
        
        fn next(self: *Iterator) ?usize {
            self.index = std.math.sub(usize, self.index, 1) catch return null;
            self.offset += self.seq_gen.prime;
            if (self.offset >= self.seq_gen.range)
                self.offset -= self.seq_gen.range;
            
            assert(self.offset < self.seq_gen.range);
            return self.offset;
        }
    };
};

const Task = struct {
    next: ?*Task = null,
    frame: ?anyframe = null,

    const List = struct {
        head: ?*Task = null,
        tail: ?*Task = null,
        
        fn from(task: *Task) List {
            task.next = null;
            return .{ .head = task, .tail = task };
        }

        fn push(self: *List, list: List) void {
            const prev = if (self.tail) |tail| &tail.next else &self.head;
            prev.* = list.head orelse return;
            self.tail = list.tail orelse unreachable;
        }
    };

    const Queue = struct {
        buffer: Buffer = .{},
        injector: Injector = .{},

        fn push(self: *Queue, task: *Task) void {
            var overflowed = List{};
            self.buffer.push(task, &overflowed);
            self.injector.push(&overflowed);
        }

        fn pop(self: *Queue, be_fair: bool) ?*Task {
            if (!be_fair) {
                return self.buffer.pop() orelse self.buffer.consume(&self.injector);
            }

            while (true) {
                return self.buffer.steal() catch |err| switch (err) {
                    error.Empty => return self.buffer.consume(&self.injector) catch null,
                    error.Contended => {
                        std.atomic.spinLoopHint();
                        continue;
                    },
                };
            }
        }

        fn steal(self: *Queue, target: *Queue) error{Empty, Contended}!*Task {
            return self.buffer.consume(&target.injector) catch |err| {
                return target.buffer.steal() catch |e| switch (e) {
                    error.Empty => err,
                    error.Contended => e,
                };
            };
        }

        fn inject(self: *Queue, list: List) void {
            self.injector.push(list);
        }

        fn fill(self: *Queue, list: List) void {
            var mut_list = list;
            self.buffer.fill(&mut_list);
            self.injector.push(&mut_list);
        }
    };

    const Injector = struct {
        head: Atomic(?*Task) = Atomic(?*Task).init(null),
        tail: Atomic(?*Task) = Atomic(?*Task).init(null),
        stub: Task = .{},

        fn next(task: *Task) *Atomic(?*Task) {
            return @ptrCast(*Atomic(?*Task), &task.next);
        }

        fn push(self: *Injector, list: List) void {
            const head = list.head orelse return;
            const tail = list.tail orelse unreachable;
            const prev = self.tail.swap(tail, .AcqRel) orelse &self.stub;
            next(prev).store(head, .Release);
        }

        fn consume(self: *Injector) error{Empty, Contended}!Consumer {
            const tail = self.tail.load(.Acquire) orelse &self.stub;
            if (tail == &self.stub)
                return error.Empty;

            const head = self.head.swap(&self.stub, .Acquire);
            if (head == @as(?*Task, &self.stub))
                return error.Contended;

            return Consumer{
                .injector = self,
                .head = head orelse &self.stub,
            };
        }

        const Consumer = struct {
            injector: *Injector,
            head: *Task,
            
            fn pop(self: *Consumer) ?*Task {
                const stub = &self.injector.stub;
                if (self.head == stub)
                    self.head = next(self.head).load(.Acquire) orelse return null;

                if (next(self.head).load(.Acquire)) |new_head| {
                    defer self.head = new_head;
                    return self.head;
                }

                const tail = self.injector.tail.load(.Monotonic) orelse stub;
                if (self.head != tail)
                    return null;

                self.injector.push(List.from(stub));
                if (next(self.head).load(.Acquire)) |new_head| {
                    defer self.head = new_head;
                    return self.head;
                }

                return null;
            }

            fn release(self: Consumer) void {
                var new_head: ?*Task = self.head;
                if (new_head == @as(?*Task, &self.injector.stub))
                    new_head = null;

                self.injector.head.store(new_head, .Release);
            }
        };
    };

    const Buffer = struct {
        head: Atomic(usize) = Atomic(usize).init(0),
        tail: Atomic(usize) = Atomic(usize).init(0),
        array: [256]Atomic(*Task) = undefined,
        
        fn push(self: *Buffer, task: *Task, overflowed: *List) void {
            const tail = self.tail.loadUnchecked();
            var head = self.head.load(.Monotonic);

            while (true) {
                const size = tail -% head;
                assert(size <= self.array.len);

                if (size < self.array.len) {
                    self.array[tail % self.array.len].store(task, .Unordered);
                    self.tail.store(tail +% 1, .Release);
                    return;
                }

                var migrate = size / 2;
                if (migrate == 0)
                    return overflowed.push(List.from(task));
                
                head = self.head.tryCompareAndSwap(head, head +% migrate, .Acquire, .Monotonic) orelse {
                    while (migrate > 0) : (migrate -= 1) {
                        const migrated = self.array[head % self.array.len].loadUnchecked();
                        const migrated_task = migrated orelse unreachable;
                        overflowed.push(List.from(migrated_task));
                    }

                    overflowed.push(List.from(task));
                    return;
                };
            }
        }

        fn pop(self: *Buffer) ?*Task {
            const tail = self.tail.loadUnchecked();
            var head = self.head.load(.Monotonic);

            var size = tail -% head;
            assert(size <= self.array.len);
            if (size == 0) {
                return null;
            }

            const new_tail = tail -% 1;
            self.tail.store(new_tail, .SeqCst);
            head = self.head.load(.SeqCst);

            size = tail -% head;
            assert(size <= self.array.len);
            
            var task = self.array[new_tail % self.array.len].loadUnchecked();
            if (size > 1) {
                return task;
            }
            
            self.tail.store(tail, .Monotonic);
            if (size == 1) {
                _ = self.head.compareAndSwap(head, tail, .Acquire, .Monotonic) orelse return task;
            }

            return null;
        }

        fn steal(self: *Buffer) error{Empty, Contended}!*Task {
            const head = self.head.load(.Acquire);
            const tail = self.tail.load(.Acquire);

            const size = tail -% head;
            if (@bitCast(isize, head) <= @bitCast(isize, tail))
                return error.Empty;

            assert(size <= self.array.len);
            const task = self.array[head % self.array.len].load(.Unordered);

            _ = self.head.compareAndSwap(head, head +% 1, .SeqCst, .Monotonic) orelse return task;
            return error.Contended;
        }

        fn consume(self: *Buffer, injector: *Injector) error{Empty, Contended}!*Task {
            var consumer = try injector.consume();
            defer consumer.release();

            const task = consumer.pop() orelse return error.Empty;
            self.fill(&consumer);
            return task;
        }

        fn fill(self: *Buffer, tasks: anytype) void {
            const tail = self.tail.loadUnchecked();
            const head = self.head.load(.Monotonic);

            const size = tail -% head;
            assert(size <= self.array.len);

            var new_tail = tail;
            defer if (tail != new_tail)
                self.tail.store(new_tail, .Release);

            var available = self.array.len - size;
            while (available > 0) : (available -= 1) {
                const task = tasks.pop() orelse break;
                self.array[new_tail % self.array.len].store(task, .Unordered);
                new_tail +%= 1;
            }
        }
    };
};

const Timer = struct {

    const AtomicU64 = switch (@sizeOf(usize)) {
        8 => struct {
            value: Atomic(u64) = Atomic(u64).init(0),

            fn load(self: *const AtomicU64) u64 {
                return self.value.load(.Acquire);
            }

            fn store(self: *AtomicU64, value: u64) void {
                return self.value.store(value, .Release);
            }
        },
        4 => struct {
            low: Atomic(u32) = Atomic(u32).init(0),
            high: Atomic(u32) = Atomic(u32).init(0),
            high2: Atomic(u32) = Atomic(u32).init(0),

            fn load(self: *const AtomicU64) u64 {
                while (true) {
                    const high = self.high.load(.Acquire);
                    const low = self.low.load(.Acquire);
                    const high2 = self.high2.load(.Monotonic);

                    if (high == high2) {
                        return (@as(u64, high) << 32) | low;
                    }
                }
            }

            fn store(self: *AtomicU64, value: u64) void {
                const low = @truncate(u32, value);
                const high = @truncate(u32, value >> 32);

                self.high2.store(high, .Monotonic);
                self.low.store(low, .Release);
                self.high.store(high, .Release);
            }
        },
        else => @compileError("architecture unsupported"),
    };

    const Instant = switch (builtin.target.os.tag) {
        .windows => WindowsInstant,
        .macos, .ios, .tvos, .watchos => PosixInstant(os.CLOCK.UPTIME_RAW),
        .freebsd, .dragonfly => PosixInstant(os.CLOCK.UPTIME_FAST),
        .linux, .openbsd => PosixInstant(os.CLOCK.BOOTTIME),
        else => PosixInstant(os.CLOCK.MONOTONIC),
    };

    fn PosixInstant(comptime clock_id: u32) type {
        return struct {
            ts: os.timespec

            fn now() Instant {
                var ts: os.timespec = undefined;
                os.clock_gettime(clock_id, &ts) catch unreachable;
                return .{ .ts = ts };
            }

            fn since(self: Instant, earlier: Instant) u64 {
                var elapsed = std.math.sub(i64, self.ts.tv_sec, earlier.ts.tv_sec) catch return 0;
                elapsed = std.math.mul(i64, elapsed, std.time.ns_per_s) catch return std.math.maxInt(i64);
                elapsed += self.ts.tv_nsec;
                elapsed -= earlier.ts.tv_nsec;
                return std.math.cast(u64, elapsed) catch 0;
            }
        };
    }

    const WindowsInstant = struct {
        qpc: u64,

        fn now() Instant {
            return .{ .qpc = os.windows.QueryPerformanceCounter() };
        }

        var qpc_scale = AtomicU64{};

        fn since(self: Instant, earlier: Instant) u64 {
            const counter = std.math.sub(u64, self.qpc, earlier.qpc) catch return 0;
            const frequency = os.windows.QueryPerformanceFrequency();

            var scale = qpc_scale.load();
            if (scale == 0) {
                const frequency = os.windows.QueryPerformanceFrequency();
                scale = (std.time.ns_per_s << 32) / frequency;
                qpc_scale.store(scale);
            }

            const scaled = @as(u96, counter) * scale;
            return @truncate(u64, scaled >> 32);
        }
    };
};

const IoEvent = struct {
    next: ?*IoEvent = null,
    states: [2]Atomic(?*Task),

    const Kind = enum {
        read,
        write,
    };

    var notified: Task = undefined;

    fn wait(self: *IoEvent, kind: IoKind) void {
        const ptr = &self.states[@enumToInt(kind)];
        var state = ptr.load(.Acquire);

        if (state != @as(?*Task, &notified)) {
            var task = Task{ .data = @frame() };
            defer state = ptr.load(.Acquire);
            suspend {
                if (ptr.compareAndSwap(null, @as(?*Task, &task), .Release, .Monotonic)) |updated| {
                    assert(updated == @as(?*Task, &notified));
                    resume @frame();
                }
            }
        }

        assert(state == @as(?*Task, &notified));
        ptr.store(null, .Monotonic);
    }

    fn notify(self: *IoEvent, kind: IoKind) ?*Task {
        const ptr = &self.states[@enumToInt(kind)];

        const state = ptr.swap(&notified, .AcqRel);
        if (state == @as(?*Task, &notified))
            return null;

        return state;
    }

    const Block = struct {
        prev: ?*Block = null,
        reserved: usize = undefined,
        events: [((64 * 1024) / @sizeOf(IoEvent)) - 1]IoEvent,
    };

    const Cache = struct {
        lock: Lock = .{},
        idle: ?*IoEvent = null,
        block: ?*Block = null,
        allocator: *std.mem.Allocator,

        fn deinit(self: *Cache) void {
            while (self.block) |b| {
                self.block = b.prev;
                self.allocator.destroy(b);
            }
        }

        fn alloc(self: *Cache) !*IoEvent {
            const held = self.lock.acquire();
            defer held.release();

            const event = self.idle orelse blk: {
                const block = try self.allocator.create(Block);
                block.prev = self.block;
                self.block = block;

                block.* = .{ .events = undefined };
                for (block.events) |*event, index| {
                    const next_index = index + 1;
                    event.next = if (next_index == block.events.len) null else &block.events[next_index];
                }

                break :blk &block.events[0];
            };

            self.idle = event.next;
            return evnet;
        }

        fn free(self: *Cache, event: *IoEvent) void {
            const held = self.lock.acquire();
            defer held.release();

            event.next = self.idle;
            self.idle = event;
        }
    };
};
