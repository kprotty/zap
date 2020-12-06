const zap = @import("../zap.zig");
const Thread = zap.runtime.Thread;
const target = zap.runtime.target;
const atomic = zap.sync.atomic;

pub const Task = extern struct {
    next: ?*Task = undefined,
    runnable: usize,

    pub fn init(frame: anyframe) Task {
        if (@alignOf(anyframe) < 2)
            @compileError("anyframe is not properly aligned");
        return Task{ .runnable = @ptrToInt(runnable) };
    }

    pub const Callback = fn(*Task) callconv(.C) void;

    pub fn initCallback(callback: Callback) Task {
        if (@alignOf(Callback) < 2)
            @compileError("Callback functions are not properly aligned");
        return Task{ .runnable = @ptrToInt(callback) | 1 };
    } 

    fn run(self: *Task) void {
        if (self.runnable & 1 != 0) {
            return (blk: {
                @setRuntimeSafety(false);
                break :blk @intToPtr(Callback, self.runnable & ~@as(usize, 1));
            })(self);
        } 

        resume blk: {
            @setRuntimeSafety(false);
            break :blk @intToPtr(anyframe, self.runnable);
        };
    }

    pub const Batch = struct {
        head: ?*Task = null,
        tail: *Task = undefined,

        pub fn from(batchable: anytype) Batch {
            switch (@TypeOf(batchable)) {
                Batch => return batchable,
                ?*Task => return Batch.from(batchable orelse return Batch{}),
                *Task => {
                    batchable.next = null;
                    return Batch{
                        .head = batchable,
                        .tail = batchable,
                    };
                },
                else => |ty| @compileError(@typeName(ty) ++ " is not batchable"),
            }
        }

        pub fn isEmpty(self: Batch) bool {
            return self.head == null;
        }

        pub fn pushBack(self: *Batch, batchable: anytype) void {
            const batch = Batch.from(batchable);
            if (self.isEmpty()) {
                self.* = batch;
            } else if (!batch.isEmpty()) {
                self.tail.next = batch.head;
                self.tail = batch.tail;
            }
        }

        pub fn pushFront(self: *Batch, batchable: anytype) void {
            const batch = Batch.from(batchable);
            if (self.isEmpty()) {
                self.* = batch;
            } else if (!batch.isEmpty()) {
                batch.tail.next = self.head;
                self.head = batch.head;
            }
        }

        pub fn popFront(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }
    };
};

pub const Worker = struct {
    pool: *Pool,
    state: usize = undefined,
    target: ?*Worker = null,
    active_next: ?*Worker = null,
    run_queue: BoundedQueue = BoundedQueue{},
    run_queue_next: ?*Task = null,
    run_queue_lifo: ?*Task = null,
    run_queue_overflow: UnboundedQueue = UnboundedQueue{},

    pub const ScheduleHint = enum {
        next,
        lifo,
        fifo,
        yield,
    };

    pub fn schedule(self: *Worker, hint: ScheduleHint, batchable: anytype) void {

    }

    fn run(pool: *Pool) void {

    }

    fn poll(self: *Worker) ?*Task {
        var tick = self.state >> 1;
        var is_waking = self.state & 1 != 0;

        const pool = self.pool;
        const task = self.pollRunnable(tick, pool) orelse return null;

        if (is_waking) {
            _ = pool.tryResume(self);
            is_waking = false;
        }

        tick += 1;
        if (tick >= ~@as(usize, 0) >> 1)
            tick = 0;

        self.state = (tick << 1) | @boolToInt(is_waking);
        return task;
    }

    fn pollRunnable(self: *Worker, tick: usize, pool: *Pool) ?*Task {
        if (tick % 61 == 0) {
            if (self.run_queue.popAndStealUnbounded(&pool.run_queue)) |task|
                return task;
            if (self.run_queue.popAndStealUnbounded(&self.run_queue_overflow)) |task|
                return task;
        }

        if (self.run_queue_next) |next| {
            const task = next;
            self.run_queue_next = null;
            return task;
        }

        if (atomic.load(&self.run_queue_lifo, .relaxed) != null) {
            if (atomic.swap(&self.run_queue_lifo, null, .consume)) |task|
                return task;
        }

        if (self.run_queue.pop()) |task| {
            return task;
        }

        if (self.run_queue.popAndStealUnbounded(&self.run_queue_overflow)) |task|
            return task;

        if (self.run_queue.popAndStealUnbounded(&pool.run_queue)) |task|
            return task;
            
        var num_workers = Pool.IdleQueue.unpack(atomic.load(&pool.idle_queue, .relaxed)).spawned;
        while (num_workers > 0) : (num_workers -= 1) {
            const target = self.target 
                orelse atomic.load(&pool.active_queue, .consume)
                orelse @panic("no active workers when work-stealing");

            self.target = target.active_next;
            if (target == self)
                continue;

            if (self.run_queue.popAndStealBounded(&target.run_queue)) |task|
                return task;

            if (self.run_queue.popAndStealUnbounded(&target.run_queue_overflow)) |task|
                return task;

            if (atomic.load(&target.run_queue_lifo) != null) {
                atomic.spinLoopHint();
                if (atomic.swap(&target.run_queue_lifo, null, .consume)) |task|
                    return task;
            }
        }

        if (self.run_queue.popAndStealUnbounded(&pool.run_queue)) |task|
            return task;

        return null;
    }
};

pub const Pool = struct {
    stack_size: u32,
    max_workers: u16,
    idle_queue: u32 = 0,
    active_queue: ?*Worker = null,
    run_queue: UnboundedQueue = UnboundedQueue{},
    
    const IdleQueue = struct {
        idle: u16 = 0,
        spawned: u16 = 0,
        state: State = .pending,

        const State = enum(u4) {
            pending = 0,
            notified,
            waking,
            waker_notified,
            shutdown,
        };

        fn pack(self: IdleQueue) u32 {
            var value: u32 = 0;
            value |= @enumToInt(self.state);
            value |= @as(u32, @intCast(u14, self.idle)) << 4;
            value |= @as(u32, @intCast(u14, self.spawned)) << (14 + 4);
            return value;
        }

        fn unpack(value: u32) IdleQueue {
            return IdleQueue{
                .state = @intToEnum(State, @truncate(u4, value)),
                .idle = @truncate(u14, value >> 4),
                .spawned = @truncate(u14, value >> (4 + 14)),
            };
        }
    };

    pub fn run(max_workers: u16, stack_size: u32, batchable: anytype) void {
        const batch = Task.Batch.from(batchable);
        if (batch.isEmpty())
            return;

        var pool = Pool{
            .stack_size = stack_size,
            .max_workers = max_workers,
        };

        pool.run_queue.push(batch);
        _ = pool.tryResume(null);
    }

    pub fn schedule(self: *Pool, batchable: anytype) void {

    }

    fn tryResume(self: *Pool, worker: ?*Worker) bool {
        var remaining_attempts: u8 = 5;
        var is_waking = if (worker) |w| (w.state & 1 != 0) else false;
        var idle_queue = IdleQueue.unpack(atomic.load(&self.idle_queue, .relaxed));

        while (true) {
            if (idle_queue.state == .shutdown)
                return false;

            const can_wake = (idle_queue.idle > 0 or idle_queue.spawned < self.max_workers);
            if (can_wake and (
                (is_waking and remaining_attempts > 0) or
                (!is_waking and idle_queue.state == .pending)
            )) {
                var new_idle_queue = idle_queue;
                new_idle_queue.state = .waking;
                if (idle_queue.idle > 0) {
                    new_idle_queue.idle -= 1;
                } else {
                    new_idle_queue.spawned += 1;
                }

                if (atomic.tryCompareAndSwap(
                    &self.idle_queue,
                    idle_queue,
                    new_idle_queue,
                    .relaxed,
                    .relaxed,
                )) |updated| {
                    idle_queue = IdleQueue.unpack(updated);
                    continue;
                }

                if (idle_queue.idle > 0) {
                    self.notify();
                    return true;
                }

                if (!target.is_parallel or idle_queue.spawned == 0) {
                    Worker.run(self);
                    return true;
                }

                if (Thread.spawn(self.stack_size, self, Worker.run)) |thread| {
                    Thread.detach(thread);
                    return true;
                } else |_| {}

                is_waking = true;
                remaining_attempts -= 1;
                atomic.spinLoopHint();
                idle_queue = IdleQueue.unpack(atomic.load(&self.idle_queue, .relaxed));
                continue;
            }

            var new_idle_queue = idle_queue;
            new_idle_queue.state = blk: {
                if (is_waking and can_wake)
                    break :blk IdleQueue.State.pending;
                if (is_waking or idle_queue.state == .pending)
                    break :blk IdleQueue.State.notified;
                if (idle_queue.state == .waking)
                    break :blk IdleQueue.State.waker_notified;
                return false;
            };

            if (atomic.tryCompareAndSwap(
                idle_queue.pack(),
                new_idle_queue.pack(),
                .relaxed,
                .relaxed,
            )) |updated| {
                idle_queue = IdleQueue.unpack(updated);
                continue;
            }

            return true;
        }
    }

    fn trySuspend(self: *Pool, worker: *Worker) ?bool {
        const is_waking = worker.state & 1 != 0;
        var idle_queue = IdleQueue.unpack(self.idle_queue.load(.relaxed));

        while (true) {
            const can_wake = idle_queue.idle > 0 or idle_queue.spawned < self.max_workers;
            const is_shutdown = idle_queue.state == .shutdown;
            const is_notified => switch (idle_queue.state) {
                .waker_notified => is_waking,
                .notified => true,
                else => false,
            };

            var new_idle_queue = idle_queue;
            if (is_shutdown) {
                new_idle_queue.spawned -= 1;
            } else if (is_notified) {
                new_idle_queue.state = if (is_waking) .waking else .pending;
            } else {
                new_idle_queue.state = if (can_wake) .pending else .notified;
                new_idle_queue.idle += 1;
            }

            if (atomic.tryCompareAndSwap(
                idle_queue.pack(),
                new_idle_queue.pack(),
                .acq_rel,
                .relaxed,
            )) |updated| {
                idle_queue = IdleQueue.unpack(updated);
                continue;
            }

            if (is_notified and is_waking)
                return true;
            if (is_notified)
                return false;
            if (!is_shutdown) {
                self.wait();
                return true;
            }

            if (new_idle_queue.counter == 0) {
                const root_worker = atomic.load()
            }
        }
    }

    pub fn shutdown(self: *Pool) void {

    }

    fn wait(self: *Pool) void {

    }

    fn notify(self: *Pool) void {

    }
};

const UnboundedQueue = struct {
    head: usize = 0,
    tail: ?*Task = null,
    stub_next: ?*Task = null,

    fn push(self: *UnboundedQueue, batchable: anytype) void {
        const batch = Task.Batch.from(batchable);
        if (batch.isEmpty())
            return;

        const prev_tail = atomic.swap(&self.tail, batch.tail, .acq_rel);
        const prev_next = if (prev_tail) |t| &t.next else &self.stub_next;
        atomic.store(prev_next, batch.head, .release);
    }

    const IS_CONSUMING: usize = 1;

    fn tryAcquireConsumer(self: *UnboundedQueue) ?Consumer {
        var head = atomic.load(&self.head, .relaxed);
        const stub = @fieldParentPtr(Task, "next", &self.stub_next);

        while (true) {
            if (head & IS_CONSUMING != 0)
                return null;
            
            const tail = atomic.load(&self.tail, .relaxed);
            if (tail == @as(?*Task, stub) or tail == null)
                return null;

            var new_head = head | IS_CONSUMING;
            if (head == 0)
                new_head |= @ptrToInt(stub);

            head = atomic.tryCompareAndSwap(
                &self.head,
                new_head,
                .acquire,
                .relaxed,
            ) orelse return Consumer{
                .queue = self,
                .stub = stub,
                .head = @intToPtr(*Task, new_head & ~IS_CONSUMING),
            };
        }
    }

    const Consumer = struct {
        queue: *UnboundedQueue,
        stub: *Task,
        head: *Task,

        fn release(self: Consumer) void {
            const new_head = @ptrToInt(self.head);
            atomic.store(&self.queue.head, new_head, .release);
        }

        fn pop(self: *Consumer) ?*Task {
            var head = self.head;
            var next = atomic.load(&head.next, .acquire);

            if (head == self.stub) {
                head = next orelse return null;
                self.head = head;
                next = atomic.load(&head.next, .acquire);
            }

            if (next) |new_head| {
                self.head = new_head;
                return head;
            }

            const tail = atomic.load(&self.queue.tail, .relaxed);
            if (head != tail)
                return null;

            self.queue.push(self.stub);
            next = atomic.load(&head.next, .acquire);

            if (next) |new_head| {
                self.head = new_head;
                return head;
            }

            return null;
        }
    };
};

const BoundedQueue = struct {
    head: u32 = 0,
    tail: u32 = 0,
    buffer: [128]*Task = undefined,

    fn push(self: *BoundedQueue, batchable: anytype) ?Batch {
        var batch = Task.Batch.from(batchable);
        if (batch.isEmpty())
            return null;

        var tail = self.tail;
        var head = atomic.load(&self.head, .relaxed);
        while (true) {
            if (batch.isEmpty())
                return null;

            const size = tail -% head;
            var remaining = self.buffer.len - size;
            if (remaining > 0) {
                while (remaining > 0) : (remaining -= 1) {
                    const task = batch.popFront() orelse break;
                    const slot = &self.buffer[tail % self.buffer.len];
                    atomic.store(slot, task, .unordered);
                    tail +%= 1;
                }

                atomic.store(&self.tail, tail, .release);
                atomic.spinLoopHint();
                head = atomic.load(&self.head, .relaxed);
                continue;
            }

            const migrate = self.buffer.len / 2;
            const new_head = head +% migrate;
            if (atomic.tryCompareAndSwap(
                head,
                new_head,
                .acquire,
                .relaxed,
            )) |updated| {
                head = updated;
                continue;
            }

            var overflowed = Task.Batch{};
            while (head != new_head) : (head +%= 1) {
                const task = self.buffer[head % self.buffer.len];
                overflowed.pushBack(task);
            }

            overflowed.pushBack(batch);
            return overflowed;
        }
    }

    fn pop(self: *BoundedQueue) ?*Task {
        const tail = self.tail;
        var head = atomic.load(&self.head, .relaxed);

        while (true) {
            if (tail == head)
                return null;

            if (atomic.tryCompareAndSwap(
                head,
                head +% 1,
                .acquire,
                .relaxed,
            )) |updated| {
                head = updated;
                continue;
            }

            return self.buffer[head % self.buffer.len];
        }
    }

    fn popAndStealUnbounded(self: *BoundedQueue, target: *UnboundedQueue) ?*Task {
        var consumer = target.tryAcquireConsumer() orelse return null;
        defer consumer.release();

        const tail = self.tail;
        var new_tail = tail;
        var first_task: ?*Task = null;
        var head = atomic.load(&self.head, .relaxed);

        while (true) {
            const task = consumer.pop() orelse break;
            if (first_task == null) {
                first_task = task;
                continue;
            }

            if (new_tail -% head < self.buffer.len) {
                const slot = &self.buffer[new_tail & self.buffer.len];
                atomic.store(slot, task, .unordered);
                new_tail +%= 1;
                continue;
            }

            atomic.spinLoopHint();
            head = atomic.load(&self.head, .relaxed);
            if (new_tail -% head == self.buffer.len)
                break;
        }

        return first_task;
    }

    fn popAndStealBounded(self: *BoundedQueue, target: *BoundedQueue) ?*Task {
        const tail = self.tail;
        const head = atomic.load(&self.head, .relaxed);
        if (tail != head)
            return self.pop();

        var target_head = atomic.load(&target.head, .acquire);
        while (true) {
            const target_tail = atomic.load(&target.tail, .acquire);
            if (target_head == target_tail)
                return null;

            const size = target_tail -% target_head;
            var steal = size - (size / 2);
            if (steal > self.buffer.len / 2) {
                atomic.spinLoopHint();
                target_head = atomic.load(&target.head, .acquire);
                continue;
            }

            var new_target_head = target_head;
            const first_task = blk: {
                const slot = &target.buffer[new_target_head % target.buffer.len];
                const task = atomic.load(slot, .unordered);
                new_target_head +%= 1;
                steal -= 1;
                break :blk task;
            };

            var new_tail = tail;
            while (steal > 0) : (steal -= 1) {
                const task = atomic.load(&target.buffer[new_target_head % target.buffer.len], .unordered);
                atomic.store(&self.buffer[new_tail % self.buffer.len], task, .unordered);
                new_target_head +%= 1;
                new_tail +%= 1;
            }

            if (atomic.tryCompareAndSwap(
                target_head,
                new_target_head,
                .acq_rel,
                .acquire,
            )) |updated| {
                target_head = updated;
                continue;
            }

            if (new_tail != tail)
                atomic.store(&self.tail, new_tail, .release);
            return first_task;
        }
    }
};
