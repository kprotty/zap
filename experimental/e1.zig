const std = @import("std");
const core = @import("../src/zap.zig").core;

const Thread = std.Thread; 
const Atomic = core.sync.atomic.Atomic;
const spinLoopHint = core.sync.atomic.spinLoopHint;

pub const Task = struct {
    next: ?*Task = undefined,
    frame: anyframe,

    pub fn initAsync(frame: anyframe) Task {
        return Task{ .frame = frame };
    }

    fn ReturnTypeOf(comptime asyncFn: anytype) type {
        return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
    }

    pub const Config = struct {
        threads: ?usize = null,
    };

    pub fn runAsync(config: Config, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        const Decorator = struct {
            fn call(fn_args: anytype, task: *Task, result: *?ReturnTypeOf(asyncFn)) void {
                suspend task.* = Task.initAsync(@frame());
                const res = @call(.{}, asyncFn, fn_args);
                suspend {
                    result.* = res;
                    Worker.getCurrent().?.getScheduler().shutdown();
                }
            }
        };

        var task: Task = undefined;
        var result: ?ReturnTypeOf(asyncFn) = null;
        var frame = async Decorator.call(args, &task, &result);

        const num_threads = 
            if (std.builtin.single_threaded) 
                @as(usize, 1)
            else if (config.threads) |threads|
                std.math.max(1, threads)
            else
                Thread.cpuCount() catch 1;

        return result orelse error.Deadlocked;
    }

    pub const Batch = extern struct {
        head: ?*Task = null,
        tail: *Task = undefined,

        pub fn from(task: *Task) Batch {
            task.next = null;
            return Batch{
                .head = task,
                .tail = task,
            };
        }

        pub fn isEmpty(self: Batch) bool {
            return self.head == null;
        }

        pub fn push(self: *Batch, task: *Task) void {
            self.pushMany(Batch.from(task));
        }

        pub fn pushMany(self: *Batch, other: Batch) void {
            if (self.isEmpty()) {
                self.* = other;
            } else if (!other.isEmpty()) {
                self.tail.next = other.head;
                self.tail = other.tail;
            }
        }

        pub fn pushFront(self: *Batch, task: *Task) void {
            self.pushFrontMany(Batch.from(task));
        }

        pub fn pushFrontMany(self: *Batch, other: Batch) void {
            if (self.isEmpty()) {
                self.* = other;
            } else if (!other.isEmpty()) {
                other.tail.next = self.head;
                self.head = other.head;
            }
        }

        pub fn pop(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }
    };

    const UnboundedQueue = struct {
        head: Atomic(*Task),
        tail: Atomic(usize),
        stub: Task,

        const IS_LOCKED: usize = 1;

        fn init(self: *UnboundedQueue) void {
            self.head.set(&self.stub);
            self.tail.set(@ptrToInt(&self.stub));
            self.stub.next = null;
        } 

        fn tryAcquire(self: *UnboundedQueue) bool {
            if (self.head.load(.relaxed) == &self.stub)
                return false;

            if (core.is_x86) {
                return asm volatile(
                    "lock btsw $0, %[ptr]"
                    : [ret] "={@ccc}" (-> u8),
                    : [ptr] "*m" (&self.tail)
                    : "cc", "memory"
                ) == 0;
            }

            var tail = self.tail.load(.relaxed);
            while (true) {
                if (tail & IS_LOCKED != 0)
                    return false;
                tail = self.tail.tryCompareAndSwap(
                    tail,
                    tail | IS_LOCKED,
                    .acquire,
                    .relaxed,
                ) orelse return true;
            }
        }

        fn release(self: *UnboundedQueue) void {
            const unlocked_tail = self.tail.get() & ~IS_LOCKED;
            self.tail.store(unlocked_tail, .release);
        }

        fn push(self: *UnboundedQueue, batch: Batch) void {
            if (batch.isEmpty())
                return;

            batch.tail.next = null;
            const prev = self.head.swap(batch.tail, .acq_rel);
            @ptrCast(*Atomic(?*Task), &prev.next).store(batch.head, .release);
        }

        fn pop(self: *UnboundedQueue) ?*Task {
            var new_tail = @intToPtr(*Task, self.tail.get() & ~IS_LOCKED);
            defer self.tail.set(@ptrToInt(new_tail) | IS_LOCKED);
            
            var tail = new_tail;
            var next = @ptrCast(*Atomic(?*Task), &tail.next).load(.consume);

            if (tail == &self.stub) {
                tail = next orelse return null;
                new_tail = tail;
                next = @ptrCast(*Atomic(?*Task), &tail.next).load(.consume);
            }

            if (next) |next_tail| {
                new_tail = next_tail;
                return tail;
            }

            const head = self.head.load(.relaxed);
            if (head != tail)
                return null;

            self.push(Batch.from(&self.stub));

            if (@ptrCast(*Atomic(?*Task), &tail.next).load(.acquire)) |next_tail| {
                new_tail = next_tail;
                return tail;
            }

            return null;
        }
    };

    const BoundedQueue = struct {
        head: Atomic(usize) = Atomic(usize).init(0),
        tail: Atomic(usize) = Atomic(usize).init(0),
        buffer: [256]Atomic(*Task) = undefined,

        fn push(self: *BoundedQueue, tasks: Batch) ?Batch {
            var batch = tasks;
            if (batch.isEmpty())
                return null;

            var tail = self.tail.get();
            var head = self.head.load(.relaxed);

            while (true) {
                var remaining = self.buffer.len - (tail -% head);
                if (remaining > 0) {
                    while (remaining > 0) : (remaining -= 1) {
                        const task = batch.pop() orelse break;
                        self.buffer[tail % self.buffer.len].store(task, .unordered);
                        tail +%= 1;
                    }

                    self.tail.store(tail, .release);
                    if (batch.isEmpty())
                        return null;

                    head = self.head.load(.relaxed);
                    continue;
                }

                const new_head = head +% (self.buffer.len / 2);
                if (self.head.tryCompareAndSwap(
                    head,
                    new_head,
                    .relaxed,
                    .relaxed,
                )) |updated| {
                    head = updated;
                    continue;
                }

                var overflowed = Batch{};
                while (head != new_head) : (head +%= 1) {
                    const task = self.buffer[head % self.buffer.len].get();
                    overflowed.push(task);
                }

                batch.pushFrontMany(overflowed);
                return batch;
            }
        }

        fn pop(self: *BoundedQueue) ?*Task {
            var tail = self.tail.get();
            var head = self.head.load(.relaxed);

            while (true) {
                if (tail == head)
                    return null;
                head = self.head.tryCompareAndSwap(
                    head,
                    head +% 1,
                    .relaxed,
                    .relaxed,
                ) orelse return self.buffer[head % self.buffer.len].get();
            }
        }

        fn tryStealUnbounded(
            noalias self: *BoundedQueue,
            noalias target: *UnboundedQueue,
            noalias injected: *bool,
        ) ?*Task {
            if (!target.tryAcquire())
                return null;

            const tail = self.tail.get();
            const head = self.head.load(.relaxed);

            var first_task = target.pop();
            var new_tail = tail;

            var remaining = self.buffer.len - (tail -% head);
            while (remaining > 0) : (remaining -= 1) {
                const task = target.pop() orelse break;
                self.buffer[new_tail % self.buffer.len].store(task, .unordered);
                new_tail +%= 1;
            }

            target.release();

            if (new_tail != tail) {
                injected.* = true;
                self.tail.store(new_tail, .release);
            }

            return first_task;
        }

        fn tryStealBounded(
            noalias self: *BoundedQueue,
            noalias target: *BoundedQueue,
            noalias injected: *bool,
        ) ?*Task {
            var tail = self.tail.get();
            var target_head = target.head.load(.relaxed);

            while (true) {
                const target_tail = target.tail.load(.acquire);
                const target_size = taregt_tail -% target_head;

                var steal = target_size - (target_size / 2);
                if (steal > target.buffer.len / 2) {
                    spinLoopHint();
                    target_head = target.head.load(.relaxed);
                    continue;
                } else if (steal == 0) {
                    return null;
                }

                const first_task = target.buffer[target_head % target.buffer.len].load(.unordered);
                var new_target_head = target_head +% 1;
                var new_tail = tail;
                steal -= 1;

                while (steal > 0) : (steal -= 1) {
                    const task = target.buffer[new_target_head % target.buffer.len].load(.unordered);
                    new_target_head +%= 1;
                    self.buffer[new_tail % self.buffer.len].store(task, .unordered);
                    new_tail +%= 1;
                }

                if (target.head.tryCompareAndSwap(
                    target_head,
                    new_target_head,
                    .relaxed,
                    .relaxed,
                )) |updated| {
                    target_head = updated;
                    continue;
                }

                if (new_tail != tail) {
                    injected.* = true;
                    self.tail.store(new_tail, .release);
                }

                return first_task;
            }
        }
    };

    const Worker = struct {
        scheduler: *Scheduler,
        state: State = .waking,
        target: ?*Worker = null,
        next: ?*Worker = undefined,
        run_queue: BoundedQueue = BoundedQueue{},
        overflow_queue: UnboundedQueue = undefined,

        const State = enum {
            waking,
            running,
            suspended,
            stopping,
            shutdown,
        };

        const Spawner = struct {
            scheduler: *Scheduler,
            thread: ?*Thread = null,
            thread_event: std.AutoResetEvent = std.AutoResetEvent{},
            spawn_event: std.AutoResetEvent = std.AutoResetEvent{},
        };

        fn spawn(scheduler: *Scheduler, use_caller_thread: bool) bool {
            var spawner = Spawner{ .scheduler = scheduler };

            if (std.builtin.single_threaded or use_caller_thread) {
                spawner.thread_event.set();
                Worker.run(&spawner);
                return true;
            }

            spawner.thread = Thread.spawn(&spawner, Worker.run) catch return false;
            spawner.thread_event.set();
            spawner.spawn_event.wait();
            return true;
        }

        threadlocal var current: ?*Worker = null;

        fn run(spawner: *Spawner) void {
            const scheduler = spawner.scheduler;
            spawner.thread_event.wait();

            const thread = spawner.thread;
            spawner.spawn_event.set();

            var self = Worker{ .scheduler = scheduler };
            self.overflow_queue.init();

            var worker_queue = scheduler.worker_queue.load(.relaxed);
            while (true) {
                self.next = worker_queue;
                worker_queue = scheduler.worker_queue.tryCompareAndSwap(
                    worker_queue,
                    &self,
                    .release,
                    .relaxed,
                ) orelse break;
            }

            const old_current = Worker.current;
            Worker.current = &self;
            defer Worker.current = old_current;

            while (true) {
                const should_poll = switch (self.state) {
                    .running, .waking => true,
                    .suspended => unreachable, // worker running when suspended
                    .stopping => false,
                    .shutdown => break,
                };

                if (should_poll) {
                    var injected = false;
                    if (self.poll(scheduler, &injected)) |task| {
                        if (injected or self.state == .waking)
                            scheduler.resumeWorker(self.state == .waking);
                        
                        self.state = .running;
                        resume task;
                        continue;
                    }
                }

                scheduler.suspendWorker(&self);
            }
        }

        fn poll(self: *Worker, scheduler: *Scheduler, injected: *bool) ?*Task {
            if (self.run_queue.pop()) |task|
                return task;

            if (self.run_queue.tryStealUnbounded(&self.overflow_queue, injected)) |task|
                return task;

            var active_workers = scheduler.idle_queue.load(.relaxed) >> 18;
            while (active_workers > 0) : (active_workers -= 1) {
                const target = self.target orelse blk: {
                    const target = scheduler.worker_queue.load(.consume);
                    self.target = target;
                    break :blk target orelse unreachable;
                };

                self.target = target.next;
                if (target == self)
                    continue;

                if (self.run_queue.tryStealBounded(&target.run_queue, injected)) |task|
                    return task;
                if (self.run_queue.tryStealUnbounded(&target.overflow_queue, injected)) |task|
                    return task;
            }

            if (self.run_queue.tryStealBounded(&scheduler.run_queue, injected)) |task|
                return task;

            return null;
        }
    };

    const Scheduler = struct {
        max_workers: u16 = undefined,
        run_queue: UnboundedQueue = undefined,
        idle_queue: Atomic(u32) = Atomic(u32).init(0),
        worker_queue: Atomic(?*Worker) = Atomic(?*Worker).init(null),
        semaphore:
        runtime: *struct {
            blocking_thread: ?*Thread,
            blocking: Scheduler,
            non_blocking: Scheduler,
        }

        fn resumeWorker(self: *Scheduler, is_caller_waking: bool) void {

        }

        fn suspendWorker(self: *Scheduler, worker: *Worker) void {

        }

        fn shutdown(self: *Scheduler) void {

        }
    };
};
