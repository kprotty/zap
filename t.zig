const std = @import("std");
const system = std.os.system;
const assert = std.debug.assert;

// https://vorbrodt.blog/2019/02/27/advanced-thread-pool/

pub fn main() !void {
    return benchPool(DispatchPool);
}

const REPS = 10;
const SPREAD = 64;
const COUNT = 10_000_000;

var win_heap = std.heap.HeapAllocator.init();

fn benchPool(comptime Pool: type) !void {
    const allocator = if (std.builtin.os.tag == .windows)
        &win_heap.allocator
    else if (std.builtin.link_libc)
        std.heap.c_allocator
    else
        std.heap.page_allocator;

    const Impl = struct {
        const Task = struct {
            index: usize,
            spawner: *Spawner,
            runnable: Pool.Runnable = Pool.Runnable.init(run),

            fn run(runnable: *Pool.Runnable) void {
                const self = @fieldParentPtr(@This(), "runnable", runnable);

                defer {
                    const counter = @atomicRmw(usize, &self.spawner.counter, .Sub, 1, .Monotonic);
                    if (counter == 1) {
                        if (@hasDecl(Pool, "Spawner")) self.spawner.s.deinit();
                        if (@atomicRmw(usize, &self.spawner.root.counter, .Sub, 1, .Monotonic) == 1) {
                            if (@hasDecl(Pool, "shutdown")) {
                                Pool.shutdown();
                            }
                        }
                    }
                }

                // std.time.sleep(1 * std.time.ns_per_us);
                var prng = std.rand.DefaultPrng.init(self.index);
                const rng = &prng.random;

                var x: usize = undefined;
                var reps: usize = REPS + (REPS * rng.uintLessThan(usize, 5));
                while (reps > 0) : (reps -= 1) {
                    x = self.index + rng.int(usize);
                }

                var keep: usize = undefined;
                @atomicStore(usize, &keep, x, .SeqCst);
            }
        };

        const Spawner = struct {
            index: usize,
            tasks: []Task,
            counter: usize,
            root: *Root,
            runnable: Pool.Runnable = Pool.Runnable.init(run),
            s: if (@hasDecl(Pool, "Spawner")) Pool.Spawner else void = undefined,

            fn run(runnable: *Pool.Runnable) void {
                const self = @fieldParentPtr(@This(), "runnable", runnable);

                if (@hasDecl(Pool, "Spawner")) 
                    self.s.init();

                for (self.tasks) |*task, offset| {
                    task.* = Task{
                        .index = self.index + offset,
                        .spawner = self,
                    };
                    if (@hasDecl(Pool, "Spawner")) {
                        self.s.schedule(&task.runnable);
                    } else {
                        Pool.schedule(&task.runnable);
                    }
                }
            }
        };

        const Root = struct {
            tasks: []Task,
            spawners: []Spawner,
            counter: usize,
            runnable: Pool.Runnable = Pool.Runnable.init(run),

            fn run(runnable: *Pool.Runnable) void {
                const self = @fieldParentPtr(@This(), "runnable", runnable);

                var offset: usize = 0;
                const chunk = self.tasks.len / self.spawners.len;

                for (self.spawners) |*spawner, index| {
                    const tasks = self.tasks[offset..][0..chunk];
                    spawner.* = Spawner{
                        .index = index,
                        .tasks = tasks,
                        .counter = tasks.len,
                        .root = self,
                    };
                    offset += chunk;
                    Pool.schedule(&spawner.runnable);
                }
            }
        };
    };

    const tasks = try allocator.alloc(Impl.Task, COUNT);
    defer allocator.free(tasks);

    const spawners = try allocator.alloc(Impl.Spawner, SPREAD);
    defer allocator.free(spawners);

    var root = Impl.Root{
        .tasks = tasks,
        .spawners = spawners,
        .counter = spawners.len,
    };

    try Pool.run(&root.runnable);
}

const BasicPool = struct {
    run_queue: ?*Runnable = null,

    const Runnable = struct {
        next: ?*Runnable = null,
        callback: fn (*Runnable) void,

        fn init(callback: fn (*Runnable) void) Runnable {
            return .{ .callback = callback };
        }
    };

    var tls_pool: ?*BasicPool = null;

    fn run(runnable: *Runnable) !void {
        var pool = BasicPool{};
        pool.push(runnable);

        const old = tls_pool;
        tls_pool = &pool;
        defer tls_pool = old;

        while (pool.pop()) |next|
            (next.callback)(next);
    }

    fn schedule(runnable: *Runnable) void {
        tls_pool.?.push(runnable);
    }

    fn push(self: *BasicPool, runnable: *Runnable) void {
        runnable.next = self.run_queue;
        self.run_queue = runnable;
    }

    fn pop(self: *BasicPool) ?*Runnable {
        const runnable = self.run_queue orelse return null;
        self.run_queue = runnable.next;
        return runnable;
    }
};

const NewPool = struct {
    const Pool = @import("./src/runtime/Pool.zig");
    const Runnable = Pool.Runnable;

    var current: ?*Pool = null;
    var event: std.Thread.StaticResetEvent = .{};

    fn run(runnable: *Runnable) !void {
        var pool = Pool.init(.{});
        defer pool.deinit();

        current = &pool;
        defer current = null;

        schedule(runnable);
        event.wait();
    }

    fn schedule(runnable: *Runnable) void {
        current.?.schedule(.{}, runnable);
    }

    fn shutdown() void {
        event.set();
    }
};

const DistributedPool = struct {
    idle: usize = 0,
    workers: []Worker,
    run_queue: UnboundedQueue,
    semaphore: Semaphore = Semaphore.init(0),

    const Runnable = struct {
        next: ?*Runnable = null,
        callback: fn(*Runnable) void,

        fn init(callback: fn(*Runnable) void) Runnable {
            return .{ .callback = callback };
        }
    };

    fn run(runnable: *Runnable) !void {
        const threads = std.math.max(1, std.Thread.cpuCount() catch 1);
        const allocator = std.heap.page_allocator;

        var self = DistributedPool{
            .workers = try allocator.alloc(Worker, threads),
            .run_queue = UnboundedQueue.init(),
        };

        defer {
            self.semaphore.deinit();
            self.run_queue.deinit();
            allocator.free(self.workers);
        }

        for (self.workers) |*worker|
            worker.* = Worker.init(&self);
        defer for (self.workers) |*worker|
            worker.deinit();
        
        self.run_queue.pushFront(Batch.from(runnable));

        for (self.workers[1..]) |*worker|
            worker.thread = try std.Thread.spawn(worker, Worker.run);
        defer for (self.workers[1..]) |*worker|
            worker.thread.wait();

        self.workers[0].run();
    }

    fn schedule(runnable: *Runnable) void {
        const worker = @intToPtr(*Worker, TLS.get());
        if (worker.run_queue.push(runnable)) |overflowed|
            worker.run_queue_overflow.pushFront(overflowed);
        worker.pool.notify(false);
    }

    const Idle = struct {
        state: State,
        waiting: usize,

        const State = enum(u2){
            pending = 0,
            notified,
            waking,
            signalled,
        };

        fn pack(self: Idle) usize {
            return @enumToInt(self.state) | (self.waiting << 2);
        }

        fn unpack(value: usize) Idle {
            return Idle{
                .state = @intToEnum(State, @truncate(u2, value)),
                .waiting = value >> 2,
            };
        }
    };

    const Wait = enum {
        retry,
        waking,
        shutdown,
    };

    fn wait(self: *DistributedPool, is_waking: bool) Wait {
        var idle = Idle.unpack(@atomicLoad(usize, &self.idle, .SeqCst));

        while (true) {
            if (idle.waiting == self.workers.len - 1) {
                self.semaphore.post();
                return Wait.shutdown;
            }

            const notified = switch (idle.state) {
                .notified => true,
                .signalled => is_waking,
                else => false,
            };

            var new_idle = idle;
            if (notified) {
                new_idle.state = if (is_waking) .waking else .pending;
            } else {
                new_idle.waiting += 1;
                new_idle.state = if (is_waking) .notified else idle.state;
            }

            if (@cmpxchgWeak(
                usize,
                &self.idle,
                idle.pack(),
                new_idle.pack(),
                .SeqCst,
                .SeqCst,
            )) |updated| {
                idle = Idle.unpack(updated);
                continue;
            }

            if (notified and is_waking)
                return Wait.waking;
            if (notified)
                return Wait.retry;

            self.semaphore.wait();
            return Wait.waking;
        }
    }

    fn notify(self: *DistributedPool, is_waking: bool) void {
        var idle = Idle.unpack(@atomicLoad(usize, &self.idle, .SeqCst));

        while (true) {
            if (!is_waking and (idle.state == .notified or idle.state == .signalled))
                return;

            var new_idle = idle;
            if (idle.waiting > 0 and (is_waking or idle.state == .pending)) {
                new_idle.waiting -= 1;
                new_idle.state = .waking;
            } else if (!is_waking and idle.state == .waking) {
                new_idle.state = .signalled;
            } else {
                new_idle.state = .notified;
            }

            if (@cmpxchgWeak(
                usize,
                &self.idle,
                idle.pack(),
                new_idle.pack(),
                .SeqCst,
                .SeqCst,
            )) |updated| {
                idle = Idle.unpack(updated);
                continue;
            }

            if (idle.waiting > new_idle.waiting)
                self.semaphore.post();
            return;
        }
    }

    const Worker = struct {
        run_queue: BoundedQueue,
        run_queue_overflow: UnboundedQueue,
        thread: *std.Thread = undefined,
        pool: *DistributedPool,

        fn init(pool: *DistributedPool) Worker {
            return Worker{
                .pool = pool,
                .run_queue = BoundedQueue.init(),
                .run_queue_overflow = UnboundedQueue.init(),
            };
        }

        fn deinit(self: *Worker) void {
            self.run_queue.deinit();
            self.run_queue_overflow.deinit();
        }

        fn run(self: *Worker) void {
            const old = TLS.get();
            TLS.set(@ptrToInt(self));
            defer TLS.set(old);

            var waking = false;
            var tick = @ptrToInt(self);
            var prng = @truncate(u32, tick >> @sizeOf(usize));

            while (true) {
                if (self.poll(.{
                    .tick = tick,
                    .rand = &prng,
                })) |runnable| {
                    if (waking)
                        self.pool.notify(waking);

                    tick +%= 1;
                    waking = false;
                    (runnable.callback)(runnable);
                    continue;
                }

                waking = switch (self.pool.wait(waking)) {
                    .retry => false,
                    .waking => true,
                    .shutdown => break,
                };
            }
        }

        fn poll(self: *Worker, args: anytype) ?*Runnable {
            if (args.tick % 256 == 0) {
                if (self.steal(args)) |runnable|
                    return runnable;
            }

            if (args.tick % 128 == 0) {
                if (self.run_queue.stealUnbounded(&self.pool.run_queue)) |runnable|
                    return runnable;
            }
            
            if (args.tick % 64 == 0) {
                if (self.run_queue.stealUnbounded(&self.run_queue_overflow)) |runnable|
                    return runnable;
            }

            if (self.run_queue.pop()) |runnable|
                return runnable;

            if (self.run_queue.stealUnbounded(&self.run_queue_overflow)) |runnable|
                return runnable;

            var attempts: u8 = 5;
            while (attempts > 0) : (attempts -= 1) {
                if (self.steal(args)) |runnable|
                    return runnable;

                if (self.run_queue.stealUnbounded(&self.pool.run_queue)) |runnable|
                    return runnable;

                std.os.sched_yield() catch spinLoopHint();
            }

            return null;
        }

        fn steal(self: *Worker, args: anytype) ?*Runnable {
            var workers = self.pool.workers;
            var index = blk: {
                var x = args.rand.*;
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                args.rand.* = x;
                break :blk x % workers.len;
            };

            var iter = workers.len;
            while (iter > 0) : (iter -= 1) {
                const worker = &workers[index];

                index += 1;
                if (index == workers.len)
                    index = 0;

                if (worker == self)
                    continue;

                if (self.run_queue.stealBounded(&worker.run_queue)) |runnable|
                    return runnable;

                if (self.run_queue.stealUnbounded(&worker.run_queue_overflow)) |runnable|
                    return runnable;
            }

            return null;
        }
    };

    const Batch = struct {
        size: usize = 0,
        head: *Runnable = undefined,
        tail: *Runnable = undefined,

        fn isEmpty(self: Batch) bool {
            return self.size == 0;
        }

        fn from(runnable: *Runnable) Batch {
            runnable.next = null;
            return Batch{
                .size = 1,
                .head = runnable,
                .tail = runnable,
            };
        }

        fn pushBack(self: *Batch, batch: Batch) void {
            if (batch.isEmpty())
                return;
            if (self.isEmpty()) {
                self.* = batch;
            } else {
                self.tail.next = batch.head;
                self.tail = batch.tail;
                self.size += batch.size;
            }
        }

        fn pushFront(self: *Batch, batch: Batch) void {
            if (batch.isEmpty())
                return;
            if (self.isEmpty()) {
                self.* = batch;
            } else {
                batch.tail.next = self.head;
                self.head = batch.head;
                self.size += batch.size;
            }
        }

        fn popFront(self: *Batch) ?*Runnable {
            if (self.isEmpty())
                return null;
            const runnable = self.head;
            self.head = runnable.next orelse undefined;
            self.size -= 1;
            return runnable;
        }
    };

    const UnboundedQueue = struct {
        head: ?*Runnable = null,
        tail: usize = 0,
        stub: Runnable = Runnable.init(undefined),

        fn init() UnboundedQueue {
            return .{};
        }

        fn deinit(self: *UnboundedQueue) void {
            self.* = undefined;
        }

        fn pushFront(self: *UnboundedQueue, batch: Batch) void {
            return self.push(batch);
        }

        fn push(self: *UnboundedQueue, batch: Batch) void {
            return self.pushBack(batch);
        }

        fn pushBack(self: *UnboundedQueue, batch: Batch) void {
            if (batch.isEmpty()) return;
            const head = @atomicRmw(?*Runnable, &self.head, .Xchg, batch.tail, .AcqRel);
            const prev = head orelse &self.stub;
            @atomicStore(?*Runnable, &prev.next, batch.head, .Release);
        }

        fn tryAcquireConsumer(self: *UnboundedQueue) ?Consumer {
            var tail = @atomicLoad(usize, &self.tail, .Monotonic);
            while (true) {
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
        head: usize = 0,
        tail: usize = 0,
        buffer: [64]*Runnable = undefined,

        fn init() BoundedQueue {
            return .{};
        }

        fn deinit(self: *BoundedQueue) void {
            self.* = undefined;
        }

        fn push(self: *BoundedQueue, runnable: *Runnable) ?Batch {
            var tail = self.tail;
            var head = @atomicLoad(usize, &self.head, .Monotonic);

            while (true) {
                if (tail -% head < self.buffer.len) {
                    @atomicStore(*Runnable, &self.buffer[tail % self.buffer.len], runnable, .Unordered);
                    @atomicStore(usize, &self.tail, tail +% 1, .Release);
                    return null;
                }

                const new_head = head +% (self.buffer.len / 2);
                if (@cmpxchgWeak(
                    usize,
                    &self.head,
                    head,
                    new_head,
                    .Acquire,
                    .Monotonic,
                )) |updated| {
                    head = updated;
                    continue;
                }

                var batch = Batch{};
                while (head != new_head) : (head +%= 1)
                    batch.pushBack(Batch.from(self.buffer[head % self.buffer.len]));
                batch.pushBack(Batch.from(runnable));
                return batch;
            }
        }

        fn pop(self: *BoundedQueue) ?*Runnable {
            var tail = self.tail;
            var head = @atomicLoad(usize, &self.head, .Monotonic);
            
            while (tail != head) {
                head = @cmpxchgWeak(
                    usize,
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
            const head = @atomicLoad(usize, &self.head, .Monotonic);
            const tail = self.tail;

            var new_tail = tail;
            while (new_tail -% head < self.buffer.len) {
                const runnable = consumer.pop() orelse break;
                @atomicStore(*Runnable, &self.buffer[new_tail % self.buffer.len], runnable, .Unordered);
                new_tail +%= 1;
            }

            if (new_tail != tail)
                @atomicStore(usize, &self.tail, new_tail, .Release);
            return first_runnable;
        }

        fn stealBounded(self: *BoundedQueue, target: *BoundedQueue) ?*Runnable {
            if (self == target)
                return self.pop();

            const head = @atomicLoad(usize, &self.head, .Monotonic);
            const tail = self.tail;
            if (tail != head)
                return self.pop();

            var target_head = @atomicLoad(usize, &target.head, .Monotonic);
            while (true) {
                const target_tail = @atomicLoad(usize, &target.tail, .Acquire);
                const target_size = target_tail -% target_head;
                if (target_size == 0)
                    return null;

                var steal = target_size - (target_size / 2);
                if (steal > target.buffer.len / 2) {
                    spinLoopHint();
                    target_head = @atomicLoad(usize, &target.head, .Monotonic);
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
                    usize,
                    &target.head,
                    target_head,
                    new_target_head,
                    .AcqRel,
                    .Monotonic,
                )) |updated| {
                    target_head = updated;
                    continue;
                }

                if (new_tail != tail)
                    @atomicStore(usize, &self.tail, new_tail, .Release);
                return first_runnable;
            }
        }
    };
};

const WindowsPool = struct {
    const Runnable = struct {
        callback: fn (*Runnable) void,

        fn init(callback: fn (*Runnable) void) Runnable {
            return .{ .callback = callback };
        }
    };

    var event = std.Thread.StaticResetEvent{};

    fn run(runnable: *Runnable) !void {
        schedule(runnable);
        event.wait();
    }

    fn schedule(runnable: *Runnable) void {
        const rc = TrySubmitThreadpoolCallback(
            struct {
                fn cb(ex: ?windows.PVOID, pt: ?windows.PVOID) callconv(.C) void {
                    const r = @ptrCast(*Runnable, @alignCast(@alignOf(Runnable), pt.?));
                    (r.callback)(r);
                }
            }.cb,
            @ptrCast(windows.PVOID, runnable),
            null,
        );
        if (rc == windows.FALSE) @panic("OOM");
    }

    fn shutdown() void {
        event.set();
    }

    const windows = std.os.windows;
    extern "kernel32" fn TrySubmitThreadpoolCallback(
        cb: fn(?windows.PVOID, ?windows.PVOID) callconv(.C) void,
        pv: ?windows.PVOID,
        ce: ?windows.PVOID,
    ) callconv(windows.WINAPI) windows.BOOL;
};

const DispatchPool = struct {
    pub const Runnable = struct {
        next: ?*Runnable = null,
        callback: fn (*Runnable) void,

        pub fn init(callback: fn (*Runnable) void) Runnable {
            return .{ .callback = callback };
        }
    };

    var sem: ?dispatch_semaphore_t = null;

    pub fn run(runnable: *Runnable) !void {
        sem = dispatch_semaphore_create(0) orelse return error.SemaphoreCreate;
        defer dispatch_release(@ptrCast(*c_void, sem.?));
        
        const queue = dispatch_queue_create(null, @ptrCast(?*c_void, &_dispatch_queue_attr_concurrent)) orelse return error.QueueCreate;
        defer dispatch_release(@ptrCast(*c_void, queue));

        dispatch_async_f(queue, @ptrCast(*c_void, runnable), dispatchRun);
        _ = dispatch_semaphore_wait(sem.?, DISPATCH_TIME_FOREVER);
    }

    pub fn schedule(runnable: *Runnable) void {
        const queue = dispatch_get_current_queue() orelse unreachable;
        dispatch_async_f(queue, @ptrCast(*c_void, runnable), dispatchRun);
    }

    fn dispatchRun(ptr: ?*c_void) callconv(.C) void {
        const runnable_ptr = @ptrCast(?*Runnable, @alignCast(@alignOf(Runnable), ptr));
        const runnable = runnable_ptr orelse unreachable;
        return (runnable.callback)(runnable);
    }

    pub fn shutdown() void {
        _ = dispatch_semaphore_signal(sem.?);
    }

    const dispatch_semaphore_t = *opaque {};
    const dispatch_time_t = u64;
    const DISPATCH_TIME_NOW = @as(dispatch_time_t, 0);
    const DISPATCH_TIME_FOREVER = ~@as(dispatch_time_t, 0);

    extern "c" fn dispatch_semaphore_create(value: isize) ?dispatch_semaphore_t;
    extern "c" fn dispatch_semaphore_wait(dsema: dispatch_semaphore_t, timeout: dispatch_time_t) isize;
    extern "c" fn dispatch_semaphore_signal(dsema: dispatch_semaphore_t) isize;
    extern "c" fn dispatch_release(object: *c_void) void;

    const dispatch_queue_t = *opaque {};
    const DISPATCH_QUEUE_PRIORITY_DEFAULT = 0;
    const dispatch_function_t = fn(?*c_void) callconv(.C) void;

    extern "c" var _dispatch_queue_attr_concurrent: usize;
    extern "c" fn dispatch_queue_create(label: ?[*:0]const u8, attr: ?*c_void) ?dispatch_queue_t;

    extern "c" fn dispatch_get_current_queue() ?dispatch_queue_t;
    extern "c" fn dispatch_async_f(queue: dispatch_queue_t, ctx: ?*c_void, work: dispatch_function_t) void;
};

pub const Semaphore = struct {
    mutex: Mutex,
    cond: Condvar,
    permits: usize,

    pub fn init(permits: usize) Semaphore {
        return .{
            .mutex = Mutex.init(),
            .cond = Condvar.init(),
            .permits = permits,
        };
    }

    pub fn deinit(self: *Semaphore) void {
        self.mutex.deinit();
        self.cond.deinit();
        self.* = undefined;
    }

    pub fn wait(self: *Semaphore) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.permits == 0)
            self.cond.wait(&self.mutex);

        self.permits -= 1;
        if (self.permits > 0)
            self.cond.signal();
    }

    pub fn post(self: *Semaphore) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.permits += 1;
        self.cond.signal();
    }
};

pub const Mutex = if (std.builtin.os.tag == .windows)
    struct {
        srwlock: SRWLOCK,

        pub fn init() Mutex {
            return .{ .srwlock = SRWLOCK_INIT };
        }

        pub fn deinit(self: *Mutex) void {
            self.* = undefined;
        }

        pub fn tryLock(self: *Mutex) bool {
            return TryAcquireSRWLockExclusive(&self.srwlock) != system.FALSE;
        }

        pub fn lock(self: *Mutex) void {
            AcquireSRWLockExclusive(&self.srwlock);
        }

        pub fn unlock(self: *Mutex) void {
            ReleaseSRWLockExclusive(&self.srwlock);
        }

        const SRWLOCK = usize;
        const SRWLOCK_INIT: SRWLOCK = 0;

        extern "kernel32" fn TryAcquireSRWLockExclusive(s: *SRWLOCK) callconv(system.WINAPI) system.BOOL;
        extern "kernel32" fn AcquireSRWLockExclusive(s: *SRWLOCK) callconv(system.WINAPI) void;
        extern "kernel32" fn ReleaseSRWLockExclusive(s: *SRWLOCK) callconv(system.WINAPI) void;
    }
else if (std.builtin.link_libc)
    struct {
        mutex: if (std.builtin.link_libc) std.c.pthread_mutex_t else void,

        pub fn init() Mutex {
            return .{ .mutex = std.c.PTHREAD_MUTEX_INITIALIZER };
        }

        pub fn deinit(self: *Mutex) void {
            const safe_rc = switch (std.builtin.os.tag) {
                .dragonfly, .netbsd => std.os.EAGAIN,
                else => 0,
            };

            const rc = std.c.pthread_mutex_destroy(&self.mutex);
            std.debug.assert(rc == 0 or rc == safe_rc);
            
            self.* = undefined;
        }

        pub fn tryLock(self: *Mutex) bool {
            return pthread_mutex_trylock(&self.mutex) == 0;
        }

        pub fn lock(self: *Mutex) void {
            const rc = std.c.pthread_mutex_lock(&self.mutex);
            if (rc != 0)
                std.debug.panic("pthread_mutex_lock() = {}\n", .{rc});
        }

        pub fn unlock(self: *Mutex) void {
            const rc = std.c.pthread_mutex_unlock(&self.mutex);
            if (rc != 0)
                std.debug.panic("pthread_mutex_unlock() = {}\n", .{rc});
        }

        extern "c" fn pthread_mutex_trylock(m: *std.c.pthread_mutex_t) callconv(.C) c_int;
    }
else if (std.builtin.os.tag == .linux)
    struct {
        state: State,

        const State = enum(i32) {
            unlocked,
            locked,
            waiting,
        };

        pub fn init() Mutex {
            return .{ .state = .unlocked };
        }

        pub fn deinit(self: *Mutex) void {
            self.* = undefined;
        }

        pub fn tryLock(self: *Mutex) bool {
            return @cmpxchgStrong(
                State,
                &self.state,
                .unlocked,
                .locked,
                .Acquire,
                .Monotonic,
            ) == null;
        }

        pub fn lock(self: *Mutex) void {
            switch (@atomicRmw(State, &self.state, .Xchg, .locked, .Acquire)) {
                .unlocked => {},
                else => |s| self.lockSlow(s),
            }
        }

        fn lockSlow(self: *Mutex, current_state: State) void {
            @setCold(true);
            var new_state = current_state;

            var spin: u8 = 0;
            while (spin < 100) : (spin += 1) {
                const state = @cmpxchgWeak(
                    State,
                    &self.state,
                    .unlocked,
                    new_state,
                    .Acquire,
                    .Monotonic,
                ) orelse return;

                switch (state) {
                    .unlocked => {},
                    .locked => {},
                    .waiting => break,
                }

                var iter = std.math.min(32, spin + 1);
                while (iter > 0) : (iter -= 1)
                    spinLoopHint();
            }

            new_state = .waiting;
            while (true) {
                switch (@atomicRmw(State, &self.state, .Xchg, new_state, .Acquire)) {
                    .unlocked => return,
                    else => {},
                }

                Futex.wait(
                    @ptrCast(*const i32, &self.state),
                    @enumToInt(new_state),
                );
            }
        }

        pub fn unlock(self: *Mutex) void {
            switch (@atomicRmw(State, &self.state, .Xchg, .unlocked, .Release)) {
                .unlocked => unreachable,
                .locked => {},
                .waiting => self.unlockSlow(),
            }
        }

        fn unlockSlow(self: *Mutex) void {
            @setCold(true);
            Futex.wake(@ptrCast(*const i32, &self.state));
        }
    }
else
    struct {
        is_locked: bool,

        pub fn init() Mutex {
            return .{ .is_locked = false };
        }

        pub fn deinit(self: *Mutex) void {
            self.* = undefined;
        }

        pub fn tryLock(self: *Mutex) bool {
            return @atomicRmw(bool, &self.is_locked, .Xchg, true, .Acquire) == false;
        }

        pub fn lock(self: *Mutex) void {
            while (!self.tryLock())
                spinLoopHint();
        }

        pub fn unlock(self: *Mutex) void {
            @atomicStore(bool, &self.is_locked, false, .Release);
        }
    };

pub const Condvar = if (std.builtin.os.tag == .windows)
    struct {
        cond: CONDITION_VARIABLE,

        pub fn init() Condvar {
            return .{ .cond = CONDITION_VARIABLE_INIT };
        }

        pub fn deinit(self: *Condvar) void {
            self.* = undefined;
        }

        pub fn wait(self: *Condvar, mutex: *Mutex) void {
            const rc = SleepConditionVariableSRW(
                &self.cond,
                &mutex.srwlock,
                system.INFINITE,
                @as(system.ULONG, 0),
            );

            std.debug.assert(rc != system.FALSE);
        }

        pub fn signal(self: *Condvar) void {
            WakeConditionVariable(&self.cond);
        }

        pub fn broadcast(self: *Condvar) void {
            WakeAllConditionVariable(&self.cond);
        }

        const SRWLOCK = usize;
        const CONDITION_VARIABLE = usize;
        const CONDITION_VARIABLE_INIT: CONDITION_VARIABLE = 0;

        extern "kernel32" fn WakeAllConditionVariable(c: *CONDITION_VARIABLE) callconv(system.WINAPI) void;
        extern "kernel32" fn WakeConditionVariable(c: *CONDITION_VARIABLE) callconv(system.WINAPI) void;
        extern "kernel32" fn SleepConditionVariableSRW(
            c: *CONDITION_VARIABLE,
            s: *SRWLOCK,
            t: system.DWORD,
            f: system.ULONG,
        ) callconv(system.WINAPI) system.BOOL;
    }
else if (std.builtin.link_libc)
    struct {
        cond: if (std.builtin.link_libc) std.c.pthread_cond_t else void,

        pub fn init() Condvar {
            return .{ .cond = std.c.PTHREAD_COND_INITIALIZER };
        }

        pub fn deinit(self: *Condvar) void {
            const safe_rc = switch (std.builtin.os.tag) {
                .dragonfly, .netbsd => std.os.EAGAIN,
                else => 0,
            };

            const rc = std.c.pthread_cond_destroy(&self.cond);
            std.debug.assert(rc == 0 or rc == safe_rc);

            self.* = undefined;
        }

        pub fn wait(self: *Condvar, mutex: *Mutex) void {
            const rc = std.c.pthread_cond_wait(&self.cond, &mutex.mutex);
            std.debug.assert(rc == 0);
        }

        pub fn signal(self: *Condvar) void {
            const rc = std.c.pthread_cond_signal(&self.cond);
            std.debug.assert(rc == 0);
        }

        pub fn broadcast(self: *Condvar) void {
            const rc = std.c.pthread_cond_broadcast(&self.cond);
            std.debug.assert(rc == 0);
        }
    }
else
    struct {
        pending: bool,
        queue_mutex: Mutex,
        queue_list: std.SinglyLinkedList(struct {
            futex: i32 = 0,

            fn wait(self: *@This()) void {
                while (@atomicLoad(i32, &self.futex, .Acquire) == 0) {
                    if (@hasDecl(Futex, "wait")) {
                        Futex.wait(&self.futex, 0);
                    } else {
                        spinLoopHint();
                    }
                }
            }

            fn notify(self: *@This()) void {
                @atomicStore(i32, &self.futex, 1, .Release);

                if (@hasDecl(Futex, "wake"))
                    Futex.wake(&self.futex);
            }
        }),

        pub fn init() Condvar {
            return .{
                .pending = false,
                .queue_mutex = Mutex.init(),
                .queue_list = .{},
            };
        }

        pub fn deinit(self: *Condvar) void {
            self.queue_mutex.deinit();
            self.* = undefined;
        }

        pub fn wait(self: *Condvar, mutex: *Mutex) void {
            var waiter = @TypeOf(self.queue_list).Node{ .data = .{} };

            {
                self.queue_mutex.lock();
                defer self.queue_mutex.unlock();

                self.queue_list.prepend(&waiter);
                @atomicStore(bool, &self.pending, true, .SeqCst);
            }

            mutex.unlock();
            waiter.data.wait();
            mutex.lock();
        }

        pub fn signal(self: *Condvar) void {
            if (@atomicLoad(bool, &self.pending, .SeqCst) == false)
                return;

            const maybe_waiter = blk: {
                self.queue_mutex.lock();
                defer self.queue_mutex.unlock();

                const maybe_waiter = self.queue_list.popFirst();
                @atomicStore(bool, &self.pending, self.queue_list.first != null, .SeqCst);
                break :blk maybe_waiter;
            };

            if (maybe_waiter) |waiter|
                waiter.data.notify();
        }

        pub fn broadcast(self: *Condvar) void {
            if (@atomicLoad(bool, &self.pending, .SeqCst) == false)
                return;

            @atomicStore(bool, &self.pending, false, .SeqCst);

            var waiters = blk: {
                self.queue_mutex.lock();
                defer self.queue_mutex.unlock();
                
                const waiters = self.queue_list;
                self.queue_list = .{};
                break :blk waiters;
            };
            
            while (waiters.popFirst()) |waiter|
                waiter.data.notify();  
        }
    };

const Futex = switch (std.builtin.os.tag) {
    .linux => struct {
        fn wait(ptr: *const i32, cmp: i32) void {
            switch (system.getErrno(system.futex_wait(
                ptr,
                system.FUTEX_PRIVATE_FLAG | system.FUTEX_WAIT,
                cmp,
                null,
            ))) {
                0 => {},
                std.os.EINTR => {},
                std.os.EAGAIN => {},
                else => unreachable,
            }
        }

        fn wake(ptr: *const i32) void {
            switch (system.getErrno(system.futex_wake(
                ptr,
                system.FUTEX_PRIVATE_FLAG | system.FUTEX_WAKE,
                @as(i32, 1),
            ))) {
                0 => {},
                std.os.EFAULT => {},
                else => unreachable,
            }
        }
    },
    else => void,
};

fn spinLoopHint() void {
    switch (std.builtin.arch) {
        .i386, .x86_64 => asm volatile("pause" ::: "memory"),
        .arm, .aarch64 => asm volatile("yield" ::: "memory"),
        else => {},
    }
}

const is_apple_silicon = std.Target.current.isDarwin() and std.builtin.arch != .x86_64;
const TLS = if (is_apple_silicon) DarwinTLS else DefaultTLS;

const DefaultTLS = struct {
    threadlocal var tls: usize = 0;

    fn get() usize {
        return tls;
    }

    fn set(worker: usize) void {
        tls = worker;
    }
};

const DarwinTLS = struct {
    fn get() usize {
        const key = getKey();
        const ptr = pthread_getspecific(key);
        return @ptrToInt(ptr);
    }

    fn set(worker: usize) void {
        const key = getKey();
        const rc = pthread_setspecific(key, @intToPtr(?*c_void, worker));
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