const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const ThreadPool = @This();

const cache_line_padding = switch (std.Target.current.cpu.arch) {
    .riscv64, .arm, .armeb, .thumb, .thumbeb, .mips, .mipsel, .mips64, .mips64el => 32,
    .x86_64, .powerpc64, .powerpc64le => 128,
    .s390x => 256,
    else => 64,
};

config: Config,
join_event: Event = .{},
workers: Atomic(?*Worker) = Atomic(?*Worker).init(null),
injected: List align(cache_line_padding) = .{},
idle_event: Event align(cache_line_padding) = .{},
sync: Atomic(u32) align(cache_line_padding) = Atomic(u32).init(@bitCast(u32, Sync{})),

pub const Config = struct {
    max_threads: u14,
    stack_size: usize = (std.Thread.SpawnConfig{}).stack_size,
};

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
        if (batch.head == null) return;
        if (self.head == null) self.tail = batch.tail;
        batch.tail.next = self.head;
        self.head = batch.head;
    }

    pub fn pop(noalias self: *Batch) ?*Runnable {
        const runnable = self.head orelse return null;
        self.head = runnable.next;
        return runnable;
    }
};

pub fn schedule(noalias self: *ThreadPool, batch: Batch) void {
    if (batch.isEmpty()) {
        return;
    }

    if (Worker.tls_current) |worker| {
        worker.push(batch);
    } else {
        self.injected.push(batch);
    }

    const sync = @bitCast(Sync, self.sync.load(.Monotonic));
    if (sync.notified) {
        return;
    }

    const is_waking = false;
    self.notify(is_waking);
}

const Sync = packed struct {
    idle: u14 = 0,
    spawned: u14 = 0,
    u32_padding: u1 = 0,
    notified: bool = false,
    state: enum(u2) {
        pending = 0,
        waking,
        signaled,
        shutdown,
    } = .pending,
};

fn notify(noalias self: *ThreadPool, is_waking: bool) void {
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
            @bitCast(u32, sync),
            @bitCast(u32, new_sync),
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

fn wait(noalias self: *ThreadPool, _is_waking: bool) error{Shutdown}!bool {
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
                @bitCast(u32, sync),
                @bitCast(u32, new_sync),
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
                @bitCast(u32, sync),
                @bitCast(u32, new_sync),
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
            @bitCast(u32, sync),
            @bitCast(u32, new_sync),
            .AcqRel,
            .Monotonic,
        )) |updated| {
            sync = @bitCast(Sync, updated);
            continue;
        }

        if (sync.idle > 0) {
            self.idle_event.shutdown();
        }

        return;
    }
}

fn register(noalias self: *ThreadPool, noalias worker: *Worker) void {
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
    const remove = @bitCast(u32, Sync{ .spawned = 1 });
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

fn join(noalias self: *ThreadPool) void {
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
    buffer: [buffer_capacity]Atomic(*Runnable) = undefined,
    tail: Atomic(BufferIndex) = Atomic(BufferIndex).init(0),
    head: Atomic(BufferIndex) align(cache_line_padding) = Atomic(BufferIndex).init(0),
    overflowed: List align(cache_line_padding) = .{},

    const BufferIndex = usize;
    const buffer_capacity = 256;
    comptime {
        assert(std.math.maxInt(BufferIndex) >= buffer_capacity);
    }
    
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

    fn push(noalias self: *Worker, batch: Batch) void {
        if (self.pushBuffer(batch)) |overflowed_batch| {
            self.overflowed.push(overflowed_batch);
        }
    }

    const Popped = struct {
        runnable: *Runnable,
        pushed: bool = false,
    };

    fn pop(
        self: *Worker,
        noalias thread_pool: *ThreadPool,
        noalias steal_target_ptr: *?*Worker,
    ) ?Popped {
        if (self.popBuffer(.single_writer)) |popped| {
            return popped;
        }

        if (self.popAndFillBuffer(&self.overflowed)) |popped| {
            return popped;
        }

        return self.steal(thread_pool, steal_target_ptr);
    }

    fn steal(
        self: *Worker,
        noalias thread_pool: *ThreadPool,
        noalias steal_target_ptr: *?*Worker,
    ) ?Popped {
        @setCold(true);
        
        var attempts: u8 = 4;
        while (attempts > 0) : (attempts -= 1) {
            if (self.popAndFillBuffer(&thread_pool.injected)) |popped| {
                return popped;
            }

            var num_workers: u16 = @bitCast(Sync, thread_pool.sync.load(.Monotonic)).spawned;
            while (num_workers > 0) : (num_workers -= 1) {
                const target = steal_target_ptr.* orelse thread_pool.workers.load(.Acquire) orelse unreachable;
                steal_target_ptr.* = target.next;

                if (target == self) {
                    continue;
                }

                if (self.popAndFillBuffer(&target.overflowed)) |popped| {
                    return popped;
                }
                
                if (target.popBuffer(.shared_access)) |popped| {
                    return popped;
                } 
            }

            std.atomic.spinLoopHint();
        }

        return null;
    }

    const BufferAccess = enum {
        single_writer,
        shared_access,
    };

    fn readBuffer(
        noalias self: *Worker,
        comptime access: BufferAccess,
        head: BufferIndex,
    ) callconv(.Inline) *Runnable {
        const slot = &self.buffer[head % buffer_capacity];
        return switch (access) {
            .single_writer => slot.loadUnchecked(),
            .shared_access => slot.load(.Unordered),
        };
    }

    fn writeBuffer(
        noalias self: *Worker, 
        noalias runnable: *Runnable,
        tail: BufferIndex,
    ) callconv(.Inline) void {
        runnable.next = self.buffer[(tail -% 1) % buffer_capacity].loadUnchecked();
        self.buffer[tail % buffer_capacity].store(runnable, .Unordered);
    } 

    fn pushBuffer(noalias self: *Worker, tasks: Batch) ?Batch {
        var batch = tasks;
        var tail = self.tail.loadUnchecked();
        var head = self.head.load(.Monotonic);

        while (true) {
            assert(!batch.isEmpty());
            const size = tail -% head;
            assert(size <= buffer_capacity);

            var free_slots = buffer_capacity - size;
            if (free_slots > 0) {
                while (free_slots > 0) : (free_slots -= 1) {
                    const runnable = batch.pop() orelse break;
                    self.writeBuffer(runnable, tail);
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

            const overflow = buffer_capacity / 2;
            if (self.head.tryCompareAndSwap(
                head,
                head +% overflow,
                .Acquire,
                .Monotonic,
            )) |updated| {
                head = updated;
                continue;
            }

            const front = self.readBuffer(.single_writer, head +% (overflow - 1));
            const back = self.readBuffer(.single_writer, head);
            back.next = null;

            batch.push(Batch {
                .head = front,
                .tail = back,
            });

            return batch;
        }
    }

    fn popBuffer(
        noalias self: *Worker, 
        comptime access: BufferAccess,
    ) ?Popped {
        while (access == .shared_access) : (std.atomic.spinLoopHint()) {
            const head = self.head.load(.Acquire);
            const tail = self.tail.load(.Acquire);

            const size = tail -% head;
            if (size == 0 or size > buffer_capacity) {
                return null;
            }

            const runnable = self.readBuffer(.shared_access, head);
            _ = self.head.compareAndSwap(
                head,
                head +% 1,
                .SeqCst,
                .Monotonic,
            ) orelse return Popped{ .runnable = runnable };
        }

        const tail = self.tail.loadUnchecked();
        var head = self.head.load(.Monotonic);

        assert(tail -% head <= buffer_capacity);
        if (head == tail) {
            return null;
        }

        const new_tail = tail -% 1;
        self.tail.store(new_tail, .SeqCst);
        head = self.head.load(.SeqCst);

        const size = tail -% head;
        assert(size <= buffer_capacity);

        const runnable = self.readBuffer(.single_writer, new_tail);
        if (size > 1) {
            return Popped{ .runnable = runnable };
        }

        self.tail.store(tail, .Monotonic);
        _ = self.head.compareAndSwap(
            head,
            tail,
            .Acquire,
            .Monotonic,
        ) orelse return Popped{ .runnable = runnable };

        return null;
    }

    fn popAndFillBuffer(self: *Worker, list: *List) ?Popped {
        @setCold(true);

        var consumer = list.consume() orelse return null;
        defer consumer.release(); 

        const tail = self.tail.loadUnchecked();
        const head = self.head.load(.Monotonic);
        assert(head == tail);

        var pushed: BufferIndex = 0;
        while (pushed < buffer_capacity) : (pushed += 1) {
            const runnable = consumer.pop() orelse break;
            self.writeBuffer(runnable, tail +% pushed);
        }

        const popped = consumer.pop() orelse blk: {
            if (pushed == 0) return null;
            pushed -= 1;
            break :blk self.readBuffer(.single_writer, tail +% pushed);
        };

        if (pushed > 0) self.tail.store(tail +% pushed, .Release);
        return Popped {
            .runnable = popped,
            .pushed = pushed > 0,
        };
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
        const head = batch.head orelse unreachable;
        const tail = batch.tail;

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

    fn consume(self: *List) ?Consumer {
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

const Event = struct {
    state: Atomic(State) = Atomic(State).init(.empty),

    const Futex = std.Thread.Futex;
    const State = enum(u32) {
        empty = 0,
        waiting,
        notified,
        shutdown,
    };

    fn wait(self: *Event) void {
        @setCold(true);

        var wake_state = State.empty;
        var state = self.state.load(.Monotonic);
        while (true) {
            switch (state) {
                .empty => {
                    state = self.state.tryCompareAndSwap(
                        state,
                        .waiting,
                        .Monotonic,
                        .Monotonic,
                    ) orelse .waiting;
                },
                .waiting => {
                    Futex.wait(
                        @ptrCast(*const Atomic(u32), &self.state),
                        @enumToInt(State.waiting),
                        null,
                    ) catch unreachable;
                    wake_state = .waiting;
                    state = self.state.load(.Monotonic);
                },
                .notified => {
                    state = self.state.tryCompareAndSwap(
                        state,
                        wake_state,
                        .Acquire,
                        .Monotonic,
                    ) orelse return;
                },
                .shutdown => {
                    return;
                },
            }
        }
    }

    fn notify(self: *Event) void {
        @setCold(true);

        var state = self.state.load(.Monotonic);
        while (true) {
            switch (state) {
                .empty => {},
                .waiting => {},
                .notified => return,
                .shutdown => return,
            }

            state = self.state.tryCompareAndSwap(
                state,
                .notified,
                .Release,
                .Monotonic,
            ) orelse return Futex.wake(
                @ptrCast(*const Atomic(u32), &self.state),
                @as(u32, 1),
            );
        }
    }

    fn shutdown(self: *Event) void {
        @setCold(true);

        self.state.store(.shutdown, .Release);
        Futex.wake(
            @ptrCast(*const Atomic(u32), &self.state),
            std.math.maxInt(u32),
        );
    }
};
