const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const ThreadPool = @This();

const arch = std.Target.current.cpu.arch;
const cache_line_padding = switch (arch) {
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
join_event: Event = .{},
workers: Atomic(?*Worker) = Atomic(?*Worker).init(null),
runnable: List align(cache_line_padding) = .{},
idle_event: Event align(cache_line_padding) = .{},
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
            self.idle_event.notify();
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
        if (sync.state == .shutdown) {
            self.idle_event.notify();
            return error.Shutdown;
        }

        if (is_waking) {
            assert(sync.state == .waking);
        }

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

        self.idle_event.wait();
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
            self.idle_event.notify();
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
        self.join_event.notify();
    }

    // If unregistering a worker, wait for a shutdown signal
    const worker = maybe_worker orelse return;
    worker.join_event.wait();

    // After receiving a shutdown signal, shutdown the next worker it's linked with
    const next_worker = worker.next orelse return;
    next_worker.join_event.notify();
}

fn join(self: *ThreadPool) void {
    @setCold(true);

    // Wait for the thread pool to be shutdown and for all workers to be unregistered.
    const sync = @bitCast(Sync, self.sync.load(.Monotonic));
    if (!(sync.state == .shutdown and sync.spawned == 0)) {
        self.join_event.wait();
    }

    // Shutdown the top-most worker, which will shutdown the next worker, and so on...
    const worker = self.workers.load(.Acquire) orelse return;
    worker.join_event.notify();
}

const Worker = struct {
    next: ?*Worker = undefined,
    join_event: Event = .{},
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

    fn push(self: *Worker, batch: Batch) void {
        if (self.buffer.push(batch)) |overflowed| {
            self.runnable.push(overflowed);
        }
    }

    const Popped = struct {
        runnable: *Runnable,
        pushed: bool = false,
    };

    fn pop(
        noalias self: *Worker,
        noalias thread_pool: *ThreadPool,
        noalias steal_target_ptr: *?*Worker,
    ) callconv(.Inline) ?Popped {
        if (self.buffer.pop()) |runnable| {
            return Popped{ .runnable = runnable };
        }

        return self.popAndSteal(thread_pool, steal_target_ptr);
    }

    fn popAndSteal(
        noalias self: *Worker, 
        noalias thread_pool: *ThreadPool,
        noalias steal_target_ptr: *?*Worker,
    ) ?Popped {
        @setCold(true);

        var steal_runnable = false;
        if (self.steal(&self.runnable, &steal_runnable)) |popped| {
            return popped;
        }

        var attempts: u32 = 32;
        while (true) {
            var was_contended = false;
            if (self.steal(&thread_pool.runnable, &was_contended)) |popped| {
                return popped;
            }

            var num_workers: usize = @bitCast(Sync, thread_pool.sync.load(.Monotonic)).spawned;
            while (num_workers > 0) : (num_workers -= 1) {
                const target_worker = steal_target_ptr.* orelse thread_pool.workers.load(.Acquire) orelse unreachable;
                steal_target_ptr.* = target_worker.next;

                if (target_worker == self and steal_runnable) {
                    steal_runnable = false;
                    return self.steal(&self.runnable, &steal_runnable) orelse continue;
                }

                if (self.steal(&target_worker.runnable, &was_contended)) |popped| {
                    return popped;
                }
                
                if (self.steal(&target_worker.buffer, &was_contended)) |popped| {
                    return popped;
                }
            }

            if (was_contended) {
                std.atomic.spinLoopHint();
                continue;
            }
            
            attempts -= 1;
            if (attempts == 0) return null;
            std.os.sched_yield() catch {};
        }
    }

    fn steal(self: *Worker, target: anytype, noalias was_contended: *bool) ?Popped {
        const err = switch (@TypeOf(target)) {
            *Buffer => blk: {
                const runnable = target.steal() catch |err| break :blk err;
                return Popped{ .runnable = runnable };
            },
            *List => blk: {
                const runnable = self.buffer.consume(target) catch |err| break :blk err;
                return Popped{ .runnable = runnable, .pushed = true };
            },
            else => |T| @compileError(@typeName(T) ++ " is not stealable"),
        };
        
        if (err == error.Contended) 
            was_contended.* = true;
        return null;
    }
};

const Buffer = struct {
    head: Atomic(usize) = Atomic(usize).init(0),
    tail: Atomic(usize) align(cache_line_padding) = Atomic(usize).init(0),
    array: [capacity]Atomic(*Runnable) = undefined,

    const capacity = 256;
    comptime {
        assert(std.math.maxInt(usize) >= capacity);
    }

    const ReadAccess = enum {
        producer,
        consumer,
    };

    fn read(self: *Buffer, index: usize, comptime access: ReadAccess) *Runnable {
        const slot = &self.array[index % capacity];
        return switch (access) {
            .producer => slot.loadUnchecked(),
            .consumer => slot.load(.Unordered),
        };
    }

    fn write(self: *Buffer, index: usize, runnable: *Runnable) void {
        runnable.next = self.read(index -% 1, .producer);
        const slot = &self.array[index % capacity];
        slot.store(runnable, .Unordered);
    }

    fn push(self: *Buffer, _batch: Batch) ?Batch {
        assert(!_batch.isEmpty());

        var batch = _batch;
        var tail = self.tail.loadUnchecked();
        var head = self.head.load(.Monotonic);

        while (true) {
            const size = tail -% head;
            assert(size <= capacity);

            var free_slots = capacity - size;
            if (free_slots > 0) {
                while (free_slots > 0) : (free_slots -= 1) {
                    const runnable = batch.pop() orelse break;
                    self.write(tail, runnable);
                    tail +%= 1;
                }

                self.tail.store(tail, .Release);
                if (batch.isEmpty()) {
                    return null;
                }

                std.atomic.spinLoopHint();
                head = self.head.load(.Monotonic);
                continue;
            } 

            var overflow = size / 2;
            if (self.head.compareAndSwap(
                head,
                head +% overflow,
                .Acquire,
                .Monotonic,
            )) |updated| {
                head = updated;
                continue;
            }

            const front = self.read(head +% (overflow - 1), .producer);
            const back = self.read(head, .producer);
            back.next = null;

            batch.push(Batch{
                .head = front,
                .tail = back,
            });

            return batch;
        }
    }

    fn pop(self: *Buffer) ?*Runnable {
        const tail = self.tail.loadUnchecked();
        var head = self.head.load(.Monotonic);
        
        assert(tail -% head <= capacity);
        if (tail == head) {
            return null;
        }

        const new_tail = tail -% 1;
        self.tail.store(new_tail, .SeqCst);
        head = self.head.load(.SeqCst);

        const size = tail -% head;
        assert(size <= capacity);

        const runnable = self.read(new_tail, .producer);
        if (size > 1) {
            return runnable;
        }

        self.tail.store(tail, .Monotonic);
        if (size == 1) {
            _ = self.head.compareAndSwap(
                head,
                tail,
                .Acquire,
                .Monotonic,
            ) orelse return runnable;
        }

        return null;
    }

    fn steal(self: *Buffer) error{Empty, Contended}!*Runnable {
        const head = self.head.load(.Acquire);
        const tail = self.tail.load(.Acquire);

        const size = tail -% head;
        if (size == 0 or size > capacity) {
            return error.Empty;
        }
        
        const runnable = self.read(head, .consumer);
        _ = self.head.compareAndSwap(
            head,
            head +% 1,
            .AcqRel,
            .Monotonic,
        ) orelse return runnable;

        return error.Contended;
    }

    fn consume(noalias self: *Buffer, noalias list: *List) error{Empty, Contended}!*Runnable {
        var consumer = try list.tryAcquireConsumer();
        defer consumer.release();

        const tail = self.tail.loadUnchecked();
        const head = self.head.load(.Monotonic);

        const size = tail -% head;
        assert(size <= capacity);
        
        var pushed: usize = 0;
        var free_slots = capacity - size;
        while (free_slots > 0) : (free_slots -= 1) {
            const runnable = consumer.pop() orelse break;
            self.write(tail +% pushed, runnable);
            pushed += 1;
        }

        const runnable = consumer.pop() orelse blk: {
            if (pushed == 0) return error.Empty;
            pushed -= 1;
            break :blk self.read(tail +% pushed, .producer);
        };

        assert(pushed <= capacity - size);
        if (pushed > 0)
            self.tail.store(tail +% pushed, .Release);

        return runnable;
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

    fn tryAcquireConsumer(self: *List) error{Empty, Contended}!Consumer {
        var stack = self.stack.load(.Monotonic);
        while (true) {
            // Return if there's no pushed pointer or HAS_LOCAL
            if (stack & ~HAS_CONSUMER == 0)
                return error.Empty;

            // Return if there's already a consumer
            if (stack & HAS_CONSUMER != 0)
                return error.Contended;

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

const Event = struct {
    state: Atomic(State) = Atomic(State).init(.empty),

    const Futex = std.Thread.Futex;
    const State = enum(u32) {
        empty = 0,
        waiting,
        notified,
    };

    fn wait(self: *Event) void {
        @setCold(true);

        var claim_state = State.empty;
        var state = self.state.load(.Monotonic);
        while (true) {
            if (state == .notified) {
                state = self.state.tryCompareAndSwap(
                    state,
                    claim_state,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
                continue;
            }

            if (state == .empty) blk: {
                state = self.state.tryCompareAndSwap(
                    state,
                    .waiting,
                    .Monotonic,
                    .Monotonic,
                ) orelse break :blk;
                continue;
            }

            Futex.wait(
                @ptrCast(*const Atomic(u32), &self.state),
                @enumToInt(State.waiting),
                null,
            ) catch unreachable;
            claim_state = State.waiting;
            state = self.state.load(.Monotonic);
        }
    }

    fn notify(self: *Event) void {
        @setCold(true);

        var state = self.state.load(.Monotonic);
        while (state != .notified) {
            if (comptime arch.isX86()) {
                state = self.state.swap(.notified, .Release);
                break;
            }

            state = self.state.tryCompareAndSwap(
                state,
                .notified,
                .Release,
                .Monotonic,
            ) orelse break;
        }

        if (state == .waiting) {
            const notify_one = 1;
            Futex.wake(
                @ptrCast(*const Atomic(u32), &self.state),
                notify_one,
            );
        }
    }
};