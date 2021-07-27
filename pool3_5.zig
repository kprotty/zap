const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;
const Futex = std.Thread.Futex;

const ThreadPool = @This();

const cache_line_padding = switch (std.Target.current.cpu.arch) {
    .riscv64, .arm, .armeb, .thumb, .thumbeb, .mips, .mipsel, .mips64, .mips64el => 32,
    .x86_64, .powerpc64, .powerpc64le => 128,
    .s390x => 256,
    else => 64,
};

pub const ThreadCount = Sync.Count;
pub const Config = struct {
    max_threads: ThreadCount,
    stack_size: usize = (std.Thread.SpawnConfig{}).stack_size,
};

config: Config,
join_event: EventCount = .{},
workers: Atomic(?*Worker) = Atomic(?*Worker).init(null),
runnable: List align(cache_line_padding) = .{},
idle_event: EventCount align(cache_line_padding) = .{},
sync: Atomic(usize) align(cache_line_padding) = Atomic(usize).init(@bitCast(usize, Sync{})),

pub fn init(config: Config) ThreadPool {
    return .{ .config = config };
}

pub fn deinit(self: *ThreadPool) void {
    self.join();
    self.* = undefined;
}

pub const Runnable = struct {
    next: ?*Runnable = null,
    runFn: fn(*Runnable) void,

    pub fn init(runFn: fn(*Runnable) void) Runnable {
        return .{ .runFn = runFn };
    }
};

pub const Batch = struct {
    head: ?*Runnable = null,
    tail: ?*Runnable = null,

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

    pub fn push(self: *Batch, batch: Batch) void {
        if (batch.head == null) return;
        if (self.isEmpty()) self.tail = batch.tail;
        batch.tail.?.next = self.head;
        self.head = batch.head;
    }

    pub fn pop(self: *Batch) ?*Runnable {
        const runnable = self.head orelse return null;
        self.head = runnable.next;
        return runnable;
    }
};

pub fn schedule(self: *ThreadPool, batch: Batch) void {
    if (batch.isEmpty()) {
        return;
    }

    if (Worker.current) |worker| {
        worker.push(batch);
    } else {
        self.runnable.push(batch);
    }

    const sync = @bitCast(Sync, self.sync.load(.Monotonic));
    if (sync.notified) {
        return;
    }

    const is_waking = false;
    self.notify(is_waking);
}

const Sync = packed struct {
    const Count = std.meta.Int(
        .unsigned,
        (std.meta.bitCount(usize) - 3) / 2,
    );

    const StateTag = std.meta.Int(
        .unsigned,
        std.meta.bitCount(usize) - 1 - (std.meta.bitCount(Count) * 2),
    );

    comptime {
        assert(@bitSizeOf(Sync) == @bitSizeOf(usize));
    }

    idle: Count = 0,
    spawned: Count = 0,
    notified: bool = false,
    state: enum(StateTag) {
        pending = 0,
        waking,
        signaled,
        shutdown,
    } = .pending,
};

fn notify(self: *ThreadPool, is_waking: bool) void {
    @setCold(true);

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
            @bitCast(usize, sync),
            @bitCast(usize, new_sync),
            .Release,
            .Monotonic,
        )) |updated| {
            sync = @bitCast(Sync, updated);
            continue;
        }

        if (sync.idle > 0 and can_wake) {
            self.idle_event.notifyOne();
        } else if (sync.spawned < max_spawn and can_wake) {
            Worker.spawn(self) catch self.unregister(null);
        }

        return;
    }
}

fn wait(self: *ThreadPool, _is_waking: bool) error{Shutdown}!bool {
    @setCold(true);

    var is_idle = false;
    var is_waking = _is_waking;
    var sync = @bitCast(Sync, self.sync.load(.Monotonic));

    while (true) {
        if (sync.state == .shutdown) return error.Shutdown;
        if (is_waking) assert(sync.state == .waking);

        if (sync.notified) {
            var new_sync = sync;
            new_sync.notified = false;
            if (is_idle) new_sync.idle -= 1;
            if (sync.state == .signaled) new_sync.state = .waking;

            if (self.sync.tryCompareAndSwap(
                @bitCast(usize, sync),
                @bitCast(usize, new_sync),
                .Acquire,
                .Monotonic,
            )) |updated| {
                sync = @bitCast(Sync, updated);
                continue;
            }

            is_waking = is_waking or sync.state == .signaled;
            return is_waking;
        }

        if (!is_idle) {
            var new_sync = sync;
            new_sync.idle += 1;
            if (is_waking) new_sync.state = .pending;

            if (self.sync.tryCompareAndSwap(
                @bitCast(usize, sync),
                @bitCast(usize, new_sync),
                .Monotonic,
                .Monotonic,
            )) |updated| {
                sync = @bitCast(Sync, updated);
                continue;
            }

            is_idle = true;
            is_waking = false;
        }

        const epoch = self.idle_event.prepare();
        sync = @bitCast(Sync, self.sync.load(.Monotonic));

        if (sync.notified) {
            self.idle_event.cancel(epoch);
        } else {
            self.idle_event.wait(epoch);
        }
        
        sync = @bitCast(Sync, self.sync.load(.Monotonic));
    }
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
            @bitCast(usize, sync),
            @bitCast(usize, new_sync),
            .AcqRel,
            .Monotonic,
        )) |updated| {
            sync = @bitCast(Sync, updated);
            continue;
        }

        if (sync.idle > 0) {
            self.idle_event.notifyAll();
        }

        return;
    }
}

fn register(noalias self: *ThreadPool, noalias worker: *Worker) void {
    @setCold(true);

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
}

fn unregister(noalias self: *ThreadPool, noalias maybe_worker: ?*Worker) void {
    @setCold(true);
    
    // Remove a spawned worker from the sync state
    const remove = @bitCast(usize, Sync{ .spawned = 1 });
    const updated = self.sync.fetchSub(remove, .AcqRel);
    const sync = @bitCast(Sync, updated);

    assert(sync.state == .shutdown);
    assert(sync.spawned >= 1);
    
    // Notify the join() threads waiting for all workers to be unregistered/joinable
    if (sync.spawned == 1) {
        self.join_event.notifyAll();
    }

    // If unregistering a worker, wait for a shutdown signal
    const worker = maybe_worker orelse return;
    worker.waitForShutdown();

    // After receiving a shutdown signal, shutdown the next worker it's linked with
    const next_worker = worker.next orelse return;
    next_worker.notifyShutdown();
}

fn join(self: *ThreadPool) void {
    @setCold(true);

    // Wait for the thread pool to be shutdown and for all workers to be unregistered.
    const epoch = self.join_event.prepare();
    const sync = @bitCast(Sync, self.sync.load(.Monotonic));
    if (sync.state == .shutdown and sync.spawned == 0) {
        self.join_event.cancel(epoch);
    } else {
        self.join_event.wait(epoch);
    }

    // Shutdown the top-most worker, which will shutdown the next worker, and so on...
    const worker = self.workers.load(.Acquire) orelse return;
    worker.notifyShutdown();
}

const Worker = struct {
    next: ?*Worker = undefined,
    shutdown_futex: Atomic(u32) = Atomic(u32).init(0),
    runnable: List align(cache_line_padding) = .{},
    buffer: Buffer align(cache_line_padding) = .{},

    threadlocal var current: ?*Worker = null;

    fn spawn(thread_pool: *ThreadPool) !void {
        const thread = try std.Thread.spawn(
            .{ .stack_size = thread_pool.config.stack_size },
            Worker.run,
            .{ thread_pool },
        );
        thread.detach();
    }

    fn run(thread_pool: *ThreadPool) void {
        var self = Worker{};
        current = &self;

        thread_pool.register(&self);
        defer thread_pool.unregister(&self);
        
        var is_waking = false;
        var steal_target: ?*Worker = null;

        while (true) {
            is_waking = thread_pool.wait(is_waking) catch break;

            while (self.pop(thread_pool, &steal_target)) |popped| {
                if (popped.pushed or is_waking) {
                    thread_pool.notify(is_waking);
                }

                is_waking = false;
                (popped.runnable.runFn)(popped.runnable);
            }
        }
    }

    fn waitForShutdown(self: *Worker) void {
        while (self.shutdown_futex.load(.Acquire) == 0) {
            Futex.wait(&self.shutdown_futex, 0, null) catch unreachable;
        }
    }

    fn notifyShutdown(self: *Worker) void {
        self.shutdown_futex.store(1, .Release);
        Futex.wake(&self.shutdown_futex, 1);
    }

    fn push(self: *Worker, batch: Batch) void {
        if (self.buffer.push(batch)) |overflowed| {
            self.runnable.push(overflowed);
        }
    }

    fn pop(
        noalias self: *Worker,
        noalias thread_pool: *ThreadPool,
        noalias steal_target_ptr: *?*Worker,
    ) callconv(.Inline) ?Buffer.Popped {
        if (self.buffer.pop()) |popped| {
            return popped;
        }

        return self.popAndSteal(thread_pool, steal_target_ptr);
    }

    fn popAndSteal(
        noalias self: *Worker, 
        noalias thread_pool: *ThreadPool,
        noalias steal_target_ptr: *?*Worker,
    ) ?Buffer.Popped {
        @setCold(true);

        if (self.buffer.popAndSteal(&self.runnable)) |popped| {
            return popped;
        }

        if (self.buffer.popAndSteal(&thread_pool.runnable)) |popped| {
            return popped;
        }

        var num_workers: usize = @bitCast(Sync, thread_pool.sync.load(.Monotonic)).spawned;
        while (num_workers > 0) : (num_workers -= 1) {
            const target_worker = steal_target_ptr.* orelse thread_pool.workers.load(.Acquire) orelse unreachable;
            steal_target_ptr.* = target_worker.next;

            if (target_worker == self) {
                continue;
            }

            if (self.buffer.popAndSteal(&target_worker.runnable)) |popped| {
                return popped;
            }
            
            if (self.buffer.popAndSteal(&target_worker.buffer)) |popped| {
                return popped;
            } 
        }

        return null;
    }
};

const Buffer = struct {
    head: Atomic(Index) align(cache_line_padding) = Atomic(Index).init(0),
    tail: Atomic(Index) align(cache_line_padding) = Atomic(Index).init(0),
    array: [capacity]Atomic(*Runnable) = undefined,

    const Index = std.meta.Int(.unsigned, std.meta.bitCount(usize) / 2);
    const capacity = 256;
    comptime {
        assert(std.math.maxInt(Index) >= capacity);
    }

    fn push(self: *Buffer, batch: Batch) ?Batch {
        assert(!batch.isEmpty());

        var runnables = batch;
        var tail = self.tail.loadUnchecked();
        var head = self.head.load(.Monotonic);

        while (true) {
            const size = tail -% head;
            assert(size <= capacity);

            var free_slots = capacity - size;
            if (free_slots > 0) {
                while (free_slots > 0) : (free_slots -= 1) {
                    const runnable = runnables.pop() orelse break;
                    self.array[tail % capacity].store(runnable, .Unordered);
                    tail +%= 1;
                }

                self.tail.store(tail, .Release);
                if (runnables.isEmpty()) {
                    return null;
                }
                
                std.atomic.spinLoopHint();
                head = self.head.load(.Monotonic);
                continue;
            }

            var overflow: Index = capacity / 2;
            if (self.head.tryCompareAndSwap(
                head,
                head +% overflow,
                .Acquire,
                .Monotonic,
            )) |updated| {
                head = updated;
                continue;
            }
            
            var overflowed = runnables;
            while (overflow > 0) : (overflow -= 1) {
                const runnable = self.array[head % capacity].loadUnchecked();
                overflowed.push(Batch.from(runnable));
                head +%= 1;
            }

            return overflowed;
        }
    }

    const Popped = struct {
        runnable: *Runnable,
        pushed: bool = false,
    };

    fn pop(self: *Buffer) ?Popped {
        const tail = self.tail.loadUnchecked();
        var head = self.head.load(.Monotonic);

        while (true) {
            const size = tail -% head;
            assert(size <= capacity);

            if (size == 0) {
                return null;
            }

            if (self.head.tryCompareAndSwap(
                head,
                head +% 1,
                .Acquire,
                .Monotonic,
            )) |updated| {
                head = updated;
                continue;
            }

            const runnable = self.array[head % capacity].loadUnchecked();
            return Popped{ .runnable = runnable };
        }
    }

    fn popAndSteal(noalias self: *Buffer, noalias target: anytype) ?Popped {
        @setCold(true);

        return switch (@TypeOf(target)) {
            *List => self.popAndStealList(target),
            *Buffer => self.popAndStealBuffer(target),
            else => |T| @compileError(@typeName(T) ++ " cannot be stolen from"),
        };
    }

    fn popAndStealList(noalias self: *Buffer, noalias target: *List) ?Popped {
        var consumer = target.tryAcquireConsumer() orelse return null;
        defer consumer.release(); 

        const tail = self.tail.loadUnchecked();
        const head = self.head.load(.Monotonic);

        const size = tail -% head;
        assert(size == 0);

        var pushed: Index = 0;
        while (pushed < capacity) : (pushed += 1) {
            const runnable = consumer.pop() orelse break;
            self.array[(tail +% pushed) % capacity].store(runnable, .Unordered);
        }

        const popped = consumer.pop() orelse blk: {
            if (pushed == 0) return null;
            pushed -= 1;
            break :blk self.array[(tail +% pushed) % capacity].loadUnchecked();
        };

        if (pushed > 0) self.tail.store(tail +% pushed, .Release);
        return Popped {
            .runnable = popped,
            .pushed = pushed > 0,
        };
    }

    fn popAndStealBuffer(noalias self: *Buffer, noalias target: *Buffer) ?Popped {
        const tail = self.tail.loadUnchecked();
        const head = self.head.load(.Monotonic);
        
        var size = tail -% head;
        assert(size == 0);

        var target_head = target.head.load(.Acquire);
        while (true) {
            const target_tail = target.tail.load(.Acquire);

            size = target_tail -% target_head;
            if (size == 0) {
                return null;
            }

            if (size > capacity) {
                std.atomic.spinLoopHint();
                target_head = target.head.load(.Acquire);
                continue;
            }

            var new_tail = tail;
            var new_target_head = target_head +% 1;
            const stolen = target.array[target_head % capacity].load(.Unordered);

            size = (size - (size / 2)) - 1;
            while (size > 0) : (size -= 1) {
                const runnable = target.array[new_target_head % capacity].load(.Unordered);
                new_target_head +%= 1;
                self.array[new_tail % capacity].store(runnable, .Unordered);
                new_tail +%= 1;
            }

            if (target.head.tryCompareAndSwap(
                target_head,
                new_target_head,
                .AcqRel,
                .Acquire,
            )) |updated| {
                target_head = updated;
                continue;
            }

            if (new_tail != tail) self.tail.store(new_tail, .Release);
            return Popped{
                .runnable = stolen,
                .pushed = new_tail != tail,
            };
        }
    }
};

const List = struct {
    stack: Atomic(usize) = Atomic(usize).init(0),
    local: ?*Runnable align(cache_line_padding) = null,

    const HAS_LOCAL: usize = 1 << 1;
    const HAS_CONSUMER: usize = 1 << 0;

    const PTR_MASK = ~(HAS_CONSUMER | HAS_LOCAL);
    comptime {
        assert(@alignOf(Runnable) >= ~PTR_MASK + 1);
    }

    fn push(self: *List, batch: Batch) void {
        assert(!batch.isEmpty());

        const head = batch.head orelse unreachable;
        const tail = batch.tail orelse unreachable;

        var stack = self.stack.load(.Monotonic);
        while (true) {
            tail.next = @intToPtr(?*Runnable, stack & PTR_MASK);

            stack = self.stack.tryCompareAndSwap(
                stack,
                @ptrToInt(head) | (stack & ~PTR_MASK),
                .Release,
                .Monotonic,
            ) orelse break;
        }
    }

    fn tryAcquireConsumer(self: *List) ?Consumer {
        var stack = self.stack.load(.Monotonic);
        while (true) {
            // Return if there's no pushed pointer or HAS_LOCAL
            if (stack & ~HAS_CONSUMER == 0)
                return null;

            // Return if there's already a consumer
            if (stack & HAS_CONSUMER != 0)
                return null;

            // Mark that the stack is being consumed and will have a local stack
            // Also claim the stack of Runnables if there is no self.local
            var new_stack = stack | HAS_CONSUMER | HAS_LOCAL;
            if (stack & HAS_LOCAL == 0) {
                new_stack &= ~PTR_MASK;
            }

            stack = self.stack.tryCompareAndSwap(
                stack,
                new_stack,
                .Acquire,
                .Monotonic,
            ) orelse return Consumer{
                .list = self,
                .local = self.local orelse @intToPtr(?*Runnable, stack & PTR_MASK),
            };
        }
    }

    const Consumer = struct {
        list: *List,
        local: ?*Runnable,

        fn pop(self: *Consumer) ?*Runnable {
            const runnable = self.local orelse return self.take();
            self.local = runnable.next;
            return runnable;
        }

        fn take(self: *Consumer) ?*Runnable {
            @setCold(true);

            var stack = self.list.stack.load(.Monotonic);
            if (stack & PTR_MASK != 0) {
                stack = self.list.stack.swap(HAS_LOCAL | HAS_CONSUMER, .Acquire);
            }

            const runnable = @intToPtr(?*Runnable, stack & PTR_MASK) orelse return null;
            self.local = runnable.next;
            return runnable;
        }

        fn release(self: Consumer) void {
            var remove: usize = HAS_CONSUMER;
            if (self.local == null) {
                remove |= HAS_LOCAL;
            }

            self.list.local = self.local;
            _ = self.list.stack.fetchSub(remove, .Release);
        }
    };
};

const EventCount = struct {
    epoch: Atomic(u32) = Atomic(u32).init(0),
    waiting: Atomic(u32) = Atomic(u32).init(0),

    fn prepare(self: *EventCount) u32 {
        _ = self.waiting.fetchAdd(1, .SeqCst);
        return self.epoch.load(.Monotonic);
    }

    fn cancel(self: *EventCount, epoch: u32) void {
        _ = epoch;
        _ = self.waiting.fetchSub(1, .SeqCst);
    }

    fn wait(self: *EventCount, epoch: u32) void {
        defer self.cancel(epoch);
        while (self.epoch.load(.Acquire) == epoch) {
            Futex.wait(&self.epoch, epoch, null) catch unreachable;
        }
    }

    fn notifyOne(self: *EventCount) void {
        return self.notify(1);
    }

    fn notifyAll(self: *EventCount) void {
        return self.notify(std.math.maxInt(u32));
    }

    fn notify(self: *EventCount, max_waiters: u32) void {
        if (self.waiting.load(.SeqCst) == 0) {
            return;
        }

        _ = self.epoch.fetchAdd(1, .Release);
        Futex.wake(&self.epoch, max_waiters);
    }
};
