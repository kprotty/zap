const std = @import("std");
const Futex = std.Thread.Futex;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;
const arch = std.Target.current.cpu.arch;

const ThreadPool = @This();

config: Config,
runnable: List = .{},
workers: Atomic(?*Worker) = Atomic(?*Worker).init(null),
sync: Atomic(u32) = Atomic(u32).init(@bitCast(u32, Sync{})),

pub const Config = struct {
    max_threads: u14,
    stack_size: usize = (std.Thread.SpawnConfig{}).stack_size,
};

pub fn init(config: Config) ThreadPool {
    return .{ .config = config };
}

pub fn deinit(self: *ThreadPool) void {
    self.join();
    self.terminate();
    self.* = undefined;
}

pub const Runnable = struct {
    next: ?*Runnable = undefined,
    runFn: fn(*Runnable) void,

    pub fn init(runFn: fn(*Runnable) void) Runnable {
        return .{ .runFn = runFn };
    }
};

pub const Batch = struct {
    head: ?*Runnable = null,
    tail: *Runnable = undefined,

    pub fn from(runnable: *Runnable) Batch {
        runnable.next = null;
        return Batch{
            .head = runnable,
            .tail = runnable,
        };
    }

    pub fn isEmpty(self: Batch) bool {
        return self.head == null;
    }

    pub fn push(noalias self: *Batch, batch: Batch) void {
        if (batch.isEmpty()) return;
        if (self.isEmpty()) {
            self.* = batch;
        } else {
            batch.tail.next = self.head;
            self.head = batch.head;
        }
    }
};

pub fn getScheduler(self: *ThreadPool) Scheduler {
    return Scheduler {
        .thread_pool = self,
        .producer = blk: {
            if (Worker.tls_current) |worker| {
                break :blk .{ .local = worker.getProducer() };
            }

            const is_single_producer = false;
            break :blk .{ .remote = self.runnable.getProducer(is_single_producer) };
        },
    };
}

pub const Scheduler = struct {
    thread_pool: *ThreadPool,
    producer: union(enum) {
        local: Worker.Producer,
        remote: List.Producer,
    },

    pub fn submit(
        noalias self: *Scheduler, 
        noalias runnable: *Runnable,
    ) void {
        return self.submitBatch(Batch.from(runnable));
    }

    pub fn submitBatch(noalias self: *Scheduler, batch: Batch) void {
        if (batch.isEmpty()) return;
        switch (self.producer) {
            .local => |*producer| producer.push(batch),
            .remote => |*producer| producer.push(batch),
        }
    }

    pub fn schedule(self: Scheduler) void {
        if (switch (self.producer) {
            .local => |producer| producer.commit(),
            .remote => |producer| producer.commit(),
        }) {
            const is_waking = false;
            self.thread_pool.notify(is_waking);
        }
    }
};

const Spin = struct {
    count: u8 = if (arch.isX86()) 100 else 10,

    fn yield(self: *Spin) bool {
        if (self.count == 0) {
            return false;
        }

        std.atomic.spinLoopHint();
        self.count -= 1;
        return true;
    }
};

const Sync = packed struct {
    idle: u14 = 0,
    spawned: u14 = 0,
    _reserved: u1 = 0,
    notified: bool = false,
    state: enum(u2) {
        pending = 0,
        waking,
        signaled,
        shutdown,
    } = .pending,
};

fn register(noalias self: *ThreadPool, noalias worker: *Worker) bool {
    var workers = self.workers.load(.Monotonic);
    while (true) {
        worker.next = workers;
        workers = self.workers.tryCompareAndSwap(
            workers,
            worker,
            .Release,
            .Monotonic,
        ) orelse break;
    }
    
    var sync = @bitCast(Sync, self.sync.load(.Monotonic));
    while (true) {
        if (sync.state == .shutdown or !sync.notified) {
            return false;
        }

        var new_sync = sync;
        new_sync.notified = false;

        const is_waking = sync.state == .signaled;
        if (is_waking) {
            new_sync.state = .waking;
        }

        if (self.sync.tryCompareAndSwap(
            @bitCast(u32, sync),
            @bitCast(u32, new_sync),
            .Acquire,
            .Monotonic,
        )) |updated| {
            sync = @bitCast(Sync, updated);
            continue;
        }

        return is_waking;
    }
}

fn unregister(noalias self: *ThreadPool, noalias maybe_worker: ?*Worker) void {
    const remove = @bitCast(u32, Sync{ .spawned = 1 });
    const updated = self.sync.fetchSub(remove, .AcqRel);
    const sync = @bitCast(Sync, updated);

    assert(sync.state == .shutdown);
    assert(sync.spawned >= 1);
    
    if (sync.spawned == 1 and sync.idle != 0) {
        const notify_all = std.math.maxInt(u32);
        Futex.wake(&self.sync, notify_all);
    }

    const worker = maybe_worker orelse return;
    worker.join();

    const next_worker = worker.next orelse return;
    next_worker.shutdown();
}

pub fn isShutdown(self: *const ThreadPool) bool {
    const sync = @bitCast(Sync, self.sync.load(.Acquire));
    return sync.state == .shutdown;
}

pub fn shutdown(self: *ThreadPool) void {
    @setCold(true);

    var sync = @bitCast(Sync, self.sync.load(.Monotonic));
    while (sync.state != .shutdown) {
        var new_sync = sync;
        new_sync.idle = 0;
        new_sync.notified = true;
        new_sync.state = .shutdown;

        if (self.sync.tryCompareAndSwap(
            @bitCast(u32, sync),
            @bitCast(u32, new_sync),
            .AcqRel,
            .Monotonic,
        )) |updated| {
            sync = @bitCast(Sync, updated);
            continue;
        }

        if (sync.idle > 0) {
            const notify_all = std.math.maxInt(u32);
            Futex.wake(&self.sync, notify_all);
        }

        return;
    }
}

fn join(noalias self: *ThreadPool) void {
    @setCold(true);

    var spin = Spin{};
    while (true) {
        const sync = @bitCast(Sync, self.sync.load(.Monotonic));
        if (sync.state == .shutdown) {
            break;
        } else if (spin.yield()) {
            continue;
        } else {
            Futex.wait(&self.sync, @bitCast(u32, sync), null) catch unreachable;
        }
    }
}

fn terminate(noalias self: *ThreadPool) void {
    @setCold(true);
    var spin = Spin{};
    var is_waiting = false;
    var sync = @bitCast(Sync, self.sync.load(.Monotonic));

    while (true) {
        assert(sync.state == .shutdown);
        if (sync.spawned == 0) {
            break;
        }

        if (spin.yield()) {
            sync = @bitCast(Sync, self.sync.load(.Monotonic));
            continue;
        }

        if (!is_waiting) {
            var old_sync = sync;
            sync.idle += 1;
            if (self.sync.tryCompareAndSwap(
                @bitCast(u32, old_sync),
                @bitCast(u32, sync),
                .Monotonic,
                .Monotonic,
            )) |updated| {
                sync = @bitCast(Sync, updated);
                continue;
            }
        }

        Futex.wait(&self.sync, @bitCast(u32, sync), null) catch unreachable;
        sync = @bitCast(Sync, self.sync.load(.Monotonic));
        is_waiting = true;
    }

    const worker = self.workers.load(.Acquire) orelse return;
    worker.shutdown();
}

fn notify(noalias self: *ThreadPool, is_waking: bool) void {
    const max_spawn = self.config.max_threads;
    var sync = @bitCast(Sync, self.sync.load(.Monotonic));

    while (true) {
        if (sync.state == .shutdown) return;
        if (is_waking) assert(sync.state == .waking);
        const can_wake = is_waking or (sync.state == .pending);

        var new_sync = sync;
        new_sync.notified = true;
        if (sync.idle > 0 and can_wake) {
            new_sync.state = .signaled;
        } else if (sync.spawned < max_spawn and can_wake) {
            new_sync.state = .signaled;
            new_sync.spawned += 1;
        } else if (is_waking) {
            new_sync.state = .pending;
        } else if (sync.notified) {
            return;
        }

        if (self.sync.tryCompareAndSwap(
            @bitCast(u32, sync),
            @bitCast(u32, new_sync),
            .Release,
            .Monotonic,
        )) |updated| {
            sync = @bitCast(Sync, updated);
            continue;
        }

        if (sync.idle > 0 and can_wake) {
            Futex.wake(&self.sync, 1);
        } else if (sync.spawned < max_spawn and can_wake) {
            Worker.spawn(self) catch self.unregister(null);
        }

        return;
    }
}

fn wait(noalias self: *ThreadPool, is_waking: bool) error{Shutdown}!bool {
    @setCold(true);
    var spin = Spin{};
    var is_waiting = false;
    var sync = @bitCast(Sync, self.sync.load(.Monotonic));

    while (true) {
        if (sync.state == .shutdown) {
            return error.Shutdown;
        }

        if (sync.notified) {
            var new_sync = sync;
            new_sync.notified = false;
            if (is_waiting) new_sync.idle -= 1;
            if (sync.state == .signaled) new_sync.state = .waking;

            if (self.sync.tryCompareAndSwap(
                @bitCast(u32, sync),
                @bitCast(u32, new_sync),
                .Acquire,
                .Monotonic,
            )) |updated| {
                sync = @bitCast(Sync, updated);
                continue;
            }

            if (sync.state == .signaled) return true;
            if (is_waiting) return false;
            return is_waking;
        }

        if (spin.yield()) {
            sync = @bitCast(Sync, self.sync.load(.Monotonic));
            continue;
        }

        if (!is_waiting) {
            var new_sync = sync;
            new_sync.idle += 1;
            if (is_waking) new_sync.state = .pending;

            if (self.sync.tryCompareAndSwap(
                @bitCast(u32, sync),
                @bitCast(u32, new_sync),
                .Monotonic,
                .Monotonic,
            )) |updated| {
                sync = @bitCast(Sync, updated);
                continue;
            }
        }

        Futex.wait(&self.sync, @bitCast(u32, sync), null) catch unreachable;
        sync = @bitCast(Sync, self.sync.load(.Monotonic));
        is_waiting = true;
    }
}

const Worker = struct {
    runnable: List = .{},
    buffer: Buffer = .{},
    next: ?*Worker = undefined,
    state: Atomic(State) = Atomic(State).init(.running),

    const State = enum(u32) {
        running,
        joining,
        shutdown,
    };

    threadlocal var tls_current: ?*Worker = null;

    fn spawn(noalias thread_pool: *ThreadPool) !void {
        const thread = try std.Thread.spawn(
            .{ .stack_size = thread_pool.config.stack_size },
            Worker.run,
            .{ thread_pool },
        );
        thread.detach();
    }

    fn run(noalias thread_pool: *ThreadPool) void {
        var self = Worker{};
        tls_current = &self;

        var is_waking = thread_pool.register(&self);
        defer thread_pool.unregister(&self);
        
        var steal_target: ?*Worker = null;
        while (true) {
            const popped = self.pop(thread_pool, &steal_target) orelse {
                is_waking = thread_pool.wait(is_waking) catch break;
                continue;
            };

            if (popped.pushed or is_waking) {
                thread_pool.notify(is_waking);
            }

            is_waking = false;
            (popped.runnable.runFn)(popped.runnable);
        }
    }

    fn getProducer(noalias self: *Worker) Producer {
        const is_single_producer = true;
        return Producer{
            .buffer_producer = self.buffer.getProducer(),
            .list_producer = self.runnable.getProducer(is_single_producer),
        };
    }

    const Producer = struct {
        buffer_producer: Buffer.Producer,
        list_producer: List.Producer,

        fn push(noalias self: *Producer, batch: Batch) void {
            const head = batch.head orelse unreachable;
            if (batch.tail == head) {
                self.pushRunnable(head);
            } else {
                self.list_producer.push(batch);
            }
        }

        fn pushRunnable(noalias self: *Producer, noalias runnable: *Runnable) void {
            const overflowed = self.buffer_producer.push(runnable) orelse return;
            self.list_producer.push(overflowed);
        }

        fn commit(self: Producer) bool {
            const buffer_committed = self.buffer_producer.commit();
            const list_committed = self.list_producer.commit();
            return buffer_committed or list_committed;
        }
    };

    fn pop(
        self: *Worker,
        noalias thread_pool: *ThreadPool,
        noalias steal_target_ptr: *?*Worker,
    ) ?Buffer.Popped {
        if (self.buffer.pop()) |runnable| {
            return Buffer.Popped{ .runnable = runnable };
        }

        return self.steal(thread_pool, steal_target_ptr);
    }

    fn steal(
        self: *Worker,
        noalias thread_pool: *ThreadPool,
        noalias steal_target_ptr: *?*Worker,
    ) ?Buffer.Popped {
        @setCold(true);
        
        var attempts: u8 = if (arch.isX86()) 32 else 8;
        while (attempts > 0) : (attempts -= 1) {
            if (self.buffer.consume(&self.runnable)) |popped| {
                return popped;
            }

            var num_workers: u16 = @bitCast(Sync, thread_pool.sync.load(.Monotonic)).spawned;
            while (num_workers > 0) : (num_workers -= 1) {
                const target_worker = steal_target_ptr.* orelse blk: {
                    const new_target = thread_pool.workers.load(.Acquire) orelse unreachable;
                    steal_target_ptr.* = new_target.next;
                    break :blk new_target;
                };

                if (target_worker == self) {
                    continue;
                }

                if (self.buffer.consume(&target_worker.runnable)) |popped| {
                    return popped;
                }
                
                if (target_worker.buffer.steal()) |runnable| {
                    return Buffer.Popped{ .runnable = runnable };
                } 
            }

            if (self.buffer.consume(&thread_pool.runnable)) |popped| {
                return popped;
            }

            std.atomic.spinLoopHint();
        }

        return null;
    }

    fn shutdown(noalias self: *Worker) void {
        const state = self.state.swap(.shutdown, .Release);
        const ptr = @ptrCast(*const Atomic(u32), &self.state);

        switch (state) {
            .running => {},
            .joining => Futex.wake(ptr, 1),
            .shutdown => unreachable,
        }
    }

    fn join(noalias self: *Worker) void {
        var spin = Spin{};
        while (true) {
            const state = self.state.load(.Acquire);
            if (state == .shutdown) {
                return;
            }

            if (state == .running) {
                if (spin.yield()) {
                    continue;
                }

                if (self.state.compareAndSwap(
                    .running,
                    .joining,
                    .Acquire,
                    .Acquire,
                )) |updated| {
                    assert(updated == .shutdown);
                    return;
                }
            }

            Futex.wait(
                @ptrCast(*const Atomic(u32), &self.state),
                @enumToInt(State.joining),
                null,
            ) catch unreachable;
        }
    }
};

const List = struct {
    input: Atomic(?*Runnable) = Atomic(?*Runnable).init(null),
    output: Atomic(usize) = Atomic(usize).init(IS_EMPTY),

    const IS_EMPTY: usize = 0b0;
    const IS_CONSUMING: usize = 0b1;
    comptime {
        assert(@alignOf(Runnable) >= (IS_CONSUMING << 1));
    }

    fn getProducer(noalias self: *List, is_single_producer: bool) Producer {
        return Producer{
            .list = self,
            .is_single_producer = is_single_producer,
        };
    }

    const Producer = struct {
        list: *List,
        batch: Batch = .{},
        is_single_producer: bool,

        fn push(noalias self: *Producer, batch: Batch) void {
            self.batch.push(batch);
        }
        
        fn commit(self: Producer) bool {
            const head = self.batch.head orelse return false;
            const tail = self.batch.tail;

            var input = self.list.input.load(.Monotonic);
            while (true) {
                tail.next = input;

                if (input == null and self.is_single_producer) {
                    self.list.input.store(head, .Release);
                    return true;
                }

                input = self.list.input.tryCompareAndSwap(
                    input,
                    head,
                    .Release,
                    .Monotonic,
                ) orelse return true;
            }
        }
    };

    fn getConsumer(noalias self: *List) ?Consumer {
        var output = self.output.load(.Monotonic);
        if (output == IS_CONSUMING) return null;
        if (output == 0 and self.input.load(.Monotonic) == null) {
            return null;
        }

        acquired: {
            if (comptime arch.isX86()) {
                output = self.output.swap(IS_CONSUMING, .Acquire);
                if (output == IS_CONSUMING) return null;
                break :acquired;       
            }

            while (true) {
                output = self.output.tryCompareAndSwap(
                    output,
                    IS_CONSUMING,
                    .Acquire,
                    .Monotonic,
                ) orelse break :acquired;
                if (output == IS_CONSUMING) return null;
                if (output == 0 and self.input.load(.Monotonic) == null) {
                    return null;
                }
            }
        }

        return Consumer{
            .list = self,
            .output = @intToPtr(?*Runnable, output),
        };
    }

    const Consumer = struct {
        list: *List,
        output: ?*Runnable,

        fn pop(self: *Consumer) ?*Runnable {
            if (self.output) |runnable| {
                self.output = runnable.next;
                return runnable;
            }

            var input = self.list.input.load(.Monotonic) orelse return null;
            input = self.list.input.swap(null, .Acquire) orelse unreachable;

            self.output = input.next;
            return input;
        }

        fn release(self: Consumer) void {
            const output = @ptrToInt(self.output);
            self.list.output.store(output, .Release);
        }
    };
};

const Buffer = struct {
    head: Atomic(Index) = Atomic(Index).init(0),
    tail: Atomic(Index) = Atomic(Index).init(0),
    array: [capacity]Atomic(*Runnable) = undefined,

    const Index = u32;
    const capacity = 256;
    comptime {
        assert(std.math.maxInt(Index) >= capacity);
    }

    fn getProducer(self: *Buffer) Producer {
        const tail = self.tail.loadUnchecked();
        const head = self.head.load(.Monotonic);
        
        const size = tail -% head;
        assert(size <= capacity);

        return Producer {
            .buffer = self,
            .tail = tail,
            .pushed = 0,
            .remaining = capacity - size,
        };
    }

    const Producer = struct {
        buffer: *Buffer,
        tail: Index,
        pushed: Index,
        remaining: Index,

        fn push(noalias self: *Producer, noalias runnable: *Runnable) ?Batch {
            return switch (self.remaining) {
                0 => self.pushOverflow(runnable),
                else => self.pushRunnable(runnable),
            };
        }

        fn pushRunnable(noalias self: *Producer, noalias runnable: *Runnable) ?Batch {
            const index = self.tail +% self.pushed;
            self.pushed += 1;

            runnable.next = null;
            if (self.pushed > 0) {
                runnable.next = self.buffer.array[(index -% 1) % capacity].loadUnchecked();
            }

            self.buffer.array[index % capacity].store(runnable, .Unordered);
            self.remaining -= 1;
            return null;
        } 

        fn pushOverflow(noalias self: *Producer, noalias runnable: *Runnable) ?Batch {
            @setCold(true);

            const tail = self.tail +% self.pushed;
            const head = self.buffer.head.load(.Monotonic);
            const size = tail -% head;
            assert(size <= capacity);

            self.remaining = capacity - size;
            if (self.remaining != 0) {
                return self.pushRunnable(runnable);
            }

            const overflow = capacity / 2;
            if (self.buffer.head.compareAndSwap(
                head,
                head +% overflow,
                .Acquire,
                .Monotonic,
            )) |updated| {
                self.remaining = capacity - (tail -% updated);
                return self.pushRunnable(runnable);
            }

            const first = runnable;
            first.next = self.buffer.array[(head +% (overflow - 1)) % capacity].loadUnchecked();

            const last = self.buffer.array[head % capacity].loadUnchecked();
            last.next = null;

            self.remaining = capacity - overflow;
            return Batch{
                .head = first,
                .tail = last,
            };
        }

        fn commit(self: Producer) bool {
            if (self.pushed == 0) {
                return false;
            }

            const tail = self.tail +% self.pushed;
            self.buffer.tail.store(tail, .Release);
            return true;
        }
    };

    fn pop(noalias self: *Buffer) ?*Runnable {
        const tail = self.tail.loadUnchecked();
        var head = self.head.load(.Monotonic);

        var size = tail -% head;
        assert(size <= capacity);
        if (size == 0) {
            return null;
        }

        const new_tail = tail -% 1;
        head = switch (arch) {
            .i386, .x86_64 => blk: {
                _ = self.tail.fetchSub(1, .SeqCst);
                break :blk self.head.load(.SeqCst);
            },
            .arm, .armeb, .thumb, .thumbeb => blk: {
                self.tail.store(new_tail, .Monotonic);
                std.atomic.fence(.SeqCst);
                break :blk self.head.load(.Monotonic);
            },
            else => blk: {
                self.tail.store(new_tail, .SeqCst);
                break :blk self.head.load(.SeqCst);
            },
        };

        size = tail -% head;
        assert(size <= capacity);

        var runnable: ?*Runnable = null;
        if (size > 0) {
            runnable = self.array[new_tail % capacity].loadUnchecked();
            if (size > 1) {
                return runnable;
            }

            assert(size == 1);
            if (self.head.compareAndSwap(
                head,
                tail,
                .SeqCst,
                .Monotonic,
            )) |_| {
                runnable = null;
            }
        }

        self.tail.store(tail, .Monotonic);
        return runnable;
    }

    fn steal(noalias self: *Buffer) ?*Runnable {
        const load_ordering: std.atomic.Ordering = switch (arch) {
            .arm, .armeb, .thumb, .thumbeb => .Monotonic,
            else => .Acquire,
        };
    
        while (true) {
            const head = self.head.load(load_ordering);
            if (load_ordering == .Monotonic) {
                std.atomic.fence(.SeqCst);
            }
            
            const tail = self.tail.load(load_ordering);
            if (tail == head or tail == (head -% 1)) {
                return null;
            }

            const runnable = self.array[head % capacity].load(.Unordered);
            if (self.head.compareAndSwap(
                head,
                head +% 1,
                .SeqCst,
                .Monotonic,
            )) |_| {
                std.atomic.spinLoopHint();
                continue;
            }
            
            return runnable;
        }
    }

    const Popped = struct {
        runnable: *Runnable,
        pushed: bool = false,
    };

    fn consume(noalias self: *Buffer, noalias list: *List) ?Popped {
        var consumer = list.getConsumer() orelse return null;
        defer consumer.release();

        var producer = self.getProducer();
        defer _ = producer.commit();

        var pushed: Index = 0;
        while (pushed < capacity) : (pushed += 1) {
            const runnable = consumer.pop() orelse break;
            const overflowed = producer.push(runnable);
            assert(overflowed == null);
        }

        const popped = consumer.pop() orelse blk: {
            if (producer.pushed == 0) {
                return null;
            }

            producer.pushed -= 1;
            const index = producer.tail +% producer.pushed;
            break :blk self.array[index % capacity].loadUnchecked();
        };

        return Popped {
            .runnable = popped,
            .pushed = producer.pushed > 0,
        };
    }
};
