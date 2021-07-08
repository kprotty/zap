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
        self.runnable.push(.shared, batch);
    }

    return self.notify();
}

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
    // Remove a spawned worker from the sync state
    const remove = @bitCast(u32, Sync{ .spawned = 1 });
    const updated = self.sync.fetchSub(remove, .AcqRel);
    const sync = @bitCast(Sync, updated);

    assert(sync.state == .shutdown);
    assert(sync.spawned >= 1);
    
    // Notify a join() thread waiting for all workers to be unregistered/joinable
    if (sync.spawned == 1) {
        const notify_all = std.math.maxInt(u32);
        Futex.wake(&self.sync, notify_all);
    }

    // If unregistering a worker, wait for a shutdown signal
    const worker = maybe_worker orelse return;
    worker.join();

    // After receiving a shutdown signal, shutdown the next worker it's linked with
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

    // Wait for shutdown
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

    // Wait for all workers to enter a joinable state
    spin = .{};
    while (true) {
        const sync = @bitCast(Sync, self.sync.load(.Monotonic));
        if (sync.spawned == 0) {
            break;
        } else if (spin.yield()) {
            continue;
        } else {
            Futex.wait(&self.sync, @bitCast(u32, sync), null) catch unreachable;
        }
    }

    // Shutdown the top-most worker, which will shutdown the next worker, and so on...
    const worker = self.workers.load(.Acquire) orelse return;
    worker.shutdown();
}

fn notify(noalias self: *ThreadPool) callconv(.Inline) void {
    const sync = @bitCast(Sync, self.sync.load(.Monotonic));
    if (!sync.notified) {
        self.notifySlow(false);
    }
}

fn notifySlow(noalias self: *ThreadPool, is_waking: bool) void {
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
    var was_idle = false;
    var was_waking = is_waking;
    var sync = @bitCast(Sync, self.sync.load(.Monotonic));

    while (true) {
        if (sync.state == .shutdown) return error.Shutdown;
        if (was_waking) assert(sync.state == .waking);

        if (sync.notified or !was_idle) {
            var new_sync = sync;
            new_sync.notified = false;
            if (sync.notified) {
                if (was_waking or sync.state == .signaled) new_sync.state = .waking;
                if (was_idle) new_sync.idle -= 1;
            } else {
                if (was_waking) new_sync.state = .pending;
                new_sync.idle += 1;
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

            if (sync.notified) {
                return was_waking or sync.state == .signaled;
            }

            sync = new_sync;
            was_idle = true;
            was_waking = false;
        }

        if (spin.yield()) {
            sync = @bitCast(Sync, self.sync.load(.Monotonic));
            continue;
        }

        Futex.wait(&self.sync, @bitCast(u32, sync), null) catch unreachable;
        sync = @bitCast(Sync, self.sync.load(.Monotonic));
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

        thread_pool.register(&self);
        defer thread_pool.unregister(&self);
        
        var is_waking = false;
        var steal_target: ?*Worker = null;

        while (true) {
            is_waking = thread_pool.wait(is_waking) catch break;

            while (self.pop(thread_pool, &steal_target)) |popped| {
                if (popped.pushed or is_waking) {
                    thread_pool.notifySlow(is_waking);
                }

                is_waking = false;
                (popped.runnable.runFn)(popped.runnable);
            }
        }
    }

    fn push(noalias self: *Worker, batch: Batch) void {
        assert(!batch.isEmpty());
        if (self.buffer.push(batch)) |overflowed| {
            self.runnable.push(.exclusive, overflowed);
        }
    }

    fn pop(
        self: *Worker,
        noalias thread_pool: *ThreadPool,
        noalias steal_target_ptr: *?*Worker,
    ) callconv(.Inline) ?Buffer.Popped {
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
                const target = steal_target_ptr.* orelse thread_pool.workers.load(.Acquire) orelse unreachable;
                steal_target_ptr.* = target.next;

                if (target == self) {
                    continue;
                }

                if (self.buffer.consume(&target.runnable)) |popped| {
                    return popped;
                }
                
                if (target.buffer.steal()) |runnable| {
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

const Access = enum {
    exclusive,
    shared,
};

const List = struct {
    input: Atomic(?*Runnable) = Atomic(?*Runnable).init(null),
    output: Atomic(usize) = Atomic(usize).init(IS_EMPTY),

    const IS_EMPTY: usize = 0b0;
    const IS_CONSUMING: usize = 0b1;
    comptime {
        assert(@alignOf(Runnable) >= (IS_CONSUMING << 1));
    }

    fn push(
        noalias self: *List, 
        comptime access: Access,
        batch: Batch, 
    ) void {
        const head = batch.head orelse unreachable;
        const tail = batch.tail;

        var input = self.input.load(.Monotonic);
        while (true) {
            tail.next = input;

            if (access == .exclusive and input == null) {
                self.input.store(head, .Release);
                return;
            }

            input = self.input.tryCompareAndSwap(
                input,
                head,
                .Release,
                .Monotonic,
            ) orelse return;
        }
    }

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

    fn read(
        noalias self: *Buffer,
        comptime access: Access,
        head: Index,
    ) callconv(.Inline) *Runnable {
        return switch (access) {
            .exclusive => self.array[head % capacity].loadUnchecked(),
            .shared => self.array[head % capacity].load(.Unordered),
        };
    }

    fn write(
        noalias self: *Buffer, 
        noalias runnable: *Runnable, 
        tail: Index,
    ) callconv(.Inline) void {
        runnable.next = self.array[(tail -% 1) % capacity].loadUnchecked();
        self.array[tail % capacity].store(runnable, .Unordered);
    } 

    fn push(noalias self: *Buffer, batch: Batch) ?Batch {
        var pushed = batch;
        assert(!pushed.isEmpty());

        var tail = self.tail.loadUnchecked();
        var head = self.head.load(.Monotonic);
        while (true) {
            const size = tail -% head;
            assert(size <= capacity);

            var remaining = capacity - size;
            if (remaining > 0) {
                while (remaining > 0) : (remaining -= 1) {
                    const runnable = pushed.pop() orelse break;
                    self.write(runnable, tail);
                    tail +%= 1;
                }

                self.tail.store(tail, .Release);
                if (pushed.isEmpty()) {
                    return null;
                }
                
                std.atomic.spinLoopHint();
                head = self.head.load(.Monotonic);
                continue;
            }

            const overflow = capacity / 2;
            if (self.head.tryCompareAndSwap(
                head,
                head +% overflow,
                .Acquire,
                .Monotonic,
            )) |updated| {
                head = updated;
                continue;
            }

            const front = self.read(.exclusive, head +% (overflow - 1));
            const back = self.read(.exclusive, head);
            back.next = null;

            pushed.push(Batch{
                .head = front,
                .tail = back,
            });

            return pushed;
        }

        return null;
    }

    fn pop(noalias self: *Buffer) ?*Runnable {
        const tail = self.tail.loadUnchecked();
        var head = self.head.load(.Monotonic);
        if (head == tail) {
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

        var runnable: ?*Runnable = null;
        if (head != tail) {
            runnable = self.read(.exclusive, new_tail);
            if (head != new_tail) {
                return runnable;
            }

            if (self.head.compareAndSwap(
                head,
                tail,
                .Acquire,
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
            const size = tail -% head;
            if (size == 0 or size > capacity) {
                return null;
            }

            const runnable = self.read(.shared, head);
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

        const tail = self.tail.loadUnchecked();
        const head = self.head.load(.Monotonic);
        assert(head == tail);

        var pushed: Index = 0;
        while (pushed < capacity) : (pushed += 1) {
            const runnable = consumer.pop() orelse break;
            self.write(runnable, tail +% pushed);
        }

        const popped = consumer.pop() orelse blk: {
            if (pushed == 0) return null;
            pushed -= 1;
            break :blk self.read(.exclusive, tail +% pushed);
        };

        if (pushed > 0) self.tail.store(tail +% pushed, .Release);
        return Popped {
            .runnable = popped,
            .pushed = pushed > 0,
        };
    }
};
