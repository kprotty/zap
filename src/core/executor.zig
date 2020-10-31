const std = @import("std");
const core = @import("./core.zig");

const Atomic = core.sync.atomic.Atomic;
const spinLoopHint = core.sync.atomic.spinLoopHint;

pub const Task = extern struct {
    next: ?*Task = undefined,

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
};

pub const Worker = extern struct {
    state: State = .waking,
    scheduler: *Scheduler,
    idle_next: ?*Worker = null,
    active_next: ?*Worker = null,
    target_worker: ?*Worker = null,
    runq_tick: Atomic(usize) = Atomic(usize).init(0),
    runq_head: Atomic(usize) = Atomic(usize).init(0),
    runq_tail: Atomic(usize) = Atomic(usize).init(0),
    runq_lifo: Atomic(?*Task) = Atomic(?*Task).init(null),
    runq_next: Atomic(?*Task) = Atomic(?*Task).init(null),
    runq_overflow: Atomic(?*Task) = Atomic(?*Task).init(null),
    runq_buffer: [256]Atomic(*Task) = undefined,

    const State = enum {
        waking,
        running,
        suspended,
        stopping,
        shutdown,
    };

    pub fn getScheduler(self: *Worker) *Scheduler {
        return self.scheduler;
    }

    pub const ScheduleHints = struct {
        use_lifo: bool = false,
        use_next: bool = false,
    };

    pub fn schedule(self: *Worker, tasks: Task.Batch, hints: ScheduleHints) void {
        var batch = tasks;
        if (batch.isEmpty())
            return;

        if (hints.use_next) {
            if (self.runq_next) |old_next|
                batch.push(old_next);
            self.runq_next = batch.pop();
            if (batch.isEmpty())
                return;
        }

        if (hints.use_lifo) {
            const new_lifo = batch.pop();
            var runq_lifo = self.runq_lifo.load(.relaxed);

            while (true) {
                const old_lifo = runq_lifo orelse {
                    self.runq_lifo.store(new_lifo, .release);
                    break;
                };

                runq_lifo = self.runq_lifo.tryCompareAndSwap(
                    old_lifo,
                    new_lifo,
                    .release,
                    .relaxed,
                ) orelse {
                    batch.pushFront(old_lifo);
                    break;
                };
            }
        }

        var tail = self.runq_tail;
        var head = self.runq_head.load(.relaxed);

        while (!batch.isEmpty()) {
            var remaining = self.runq_buffer.len - (tail -% head);
            if (remaining > 0) {
                while (remaining > 0) : (remaining -= 1) {
                    const task = batch.pop() orelse break;
                    self.runq_buffer[tail % self.runq_buffer.len].store(task, .unordered);
                    tail +%= 1;
                }

                self.runq_tail.store(tail, .release);
                head = self.runq_head.load(.relaxed);
                continue;
            }

            const new_head = head +% (self.runq_buffer.len / 2);
            if (self.runq_head.tryCompareAndSwap(
                head,
                new_head,
                .relaxed,
                .relaxed,
            )) |updated| {
                head = updated;
                continue;
            }

            var overflowed = Task.Batch{};
            while (head != new_head) : (head +%= 1) {
                const task = self.runq_buffer[head % self.runq_buffer.len].get();
                overflowed.push(task);
            }

            batch.pushFrontMany(overflowed);
            self.pushOverflow(batch);
            break;
        }

        const scheduler = self.getScheduler();
        scheduler.resumeWorker(false);
    }

    fn pushOverflow(self: *Worker, batch: Task.Batch) void {
        if (batch.isEmpty())
            return;

        var overflow = self.runq_overflow.load(.relaxed);
        while (true) {
            batch.tail.next = overflow;

            if (overflow == null) {
                self.runq_overflow.store(batch.head, .release);
                break;
            }

            overflow = self.runq_overflow.tryCompareAndSwap(
                overflow,
                batch.head,
                .release,
                .relaxed,
            ) orelse break;
        }
    }

    fn poll(self: *Worker, scheduler: *Scheduler, injected: *bool) ?*Task {
        var polled = Task.Batch{};
        scheduler.platform.call(.{
            .worker = self,
            .polled = &polled,
            .intention = .eager,
        });

        if (polled.pop()) |first_task| {
            if (!polled.isEmpty()) {
                self.pushOverflow(polled);
                injected.* = true;
            }
            return first_task;
        }

        if (self.runq_next) |next| {
            const task = next;
            self.runq_next = null;
            return task;
        }

        if (self.runq_tick % 61 == 0) {
            var overflow = self.runq_overflow.load(.relaxed);
            while (overflow) |first_task| {
                overflow = self.runq_overflow.tryCompareAndSwap(
                    first_task,
                    null,
                    .relaxed,
                    .relaxed,
                ) orelse {
                    if (first_task.next) |next| {
                        self.runq_overflow.store(next, .release);
                        injected.* = true;
                    }
                    return first_task;
                };
            }
        }

        var lifo = self.runq_lifo.load(.relaxed);
        while (lifo) |task| {
            lifo = self.runq_lifo.tryCompareAndSwap(
                lifo,
                null,
                .relaxed,
                .relaxed,
            ) orelse return task;
        }

        var tail = self.runq_tail.get();
        var head = self.runq_head.load(.relaxed);
        while (tail != head) {
            head = self.runq_head.tryCompareAndSwap(
                head,
                head +% 1,
                .relaxed,
                .relaxed,
            ) orelse return self.runq_buffer[head % self.runq_buffer.len].get();
        }

        var overflow = self.runq_overflow.load(.relaxed);
        while (overflow) |first_task| {
            overflow = self.runq_overflow.tryCompareAndSwap(
                first_task,
                null,
                .relaxed,
                .relaxed,
            ) orelse {
                self.inject(first_task.next, tail, injected);
                return first_task;
            };
        }

        var steal_attempts: usize = 1;
        while (steal_attempts > 0) : (steal_attempts -= 1) {
            
            var active_workers = scheduler.active_workers.load(.relaxed);
            while (active_workers > 0) : (active_workers -= 1) {

                const target = self.target_worker orelse blk: {
                    const target = scheduler.active_queue.load(.acquire);
                    self.target_worker = target;
                    break :blk (target orelse @panic("no active workers when trying to steal"));
                };

                self.target_worker = target.active_next;
                if (target == self)
                    continue;

                var target_head = target.runq_head.load(.relaxed);
                while (true) {
                    const target_tail = target.runq_tail.load(.acquire);

                    const target_size = target_tail -% target_head;
                    if (target_size > target.runq_buffer.len) {
                        spinLoopHint();
                        target_head = target.runq_head.load(.relaxed);
                        continue;
                    }

                    var steal = target_size - (target_size / 2);
                    if (steal == 0) {
                        if (target.runq_overflow.load(.relaxed)) |first_task| {
                            _ = target.runq_overflow.tryCompareAndSwap(
                                first_task,
                                null,
                                .acquire,
                                .relaxed,
                            ) orelse {
                                self.inject(first_task.next, tail, injected);
                                return first_task;
                            };
                        } else if (target.runq_lifo.load(.relaxed)) |task| {
                            _ = target.runq_lifo.tryCompareAndSwap(
                                task,
                                null,
                                .acquire,
                                .relaxed,
                            ) orelse return task;
                        } else {
                            break;
                        }

                        spinLoopHint();
                        target_head = target.runq_head.load(.relaxed);
                        continue;
                    }

                    const first_task = target.runq_buffer[target_head % target.runq_buffer.len].load(.unordered);
                    var new_target_head = target_head +% 1;
                    var new_tail = tail;
                    steal -= 1;

                    while (steal > 0) : (steal -= 1) {
                        const task = target.runq_buffer[new_target_head % target.runq_buffer.len], .unordered);
                        new_target_head +%= 1;
                        self.runq_buffer[new_tail % self.runq_buffer.len].store(task, .unordered);
                        new_tail +%= 1;
                    }

                    if (target.runq_head.tryCompareAndSwap(
                        target_head,
                        new_target_head,
                        .relaxed,
                        .relaxed,
                    )) |updated| {
                        target_head = updated;
                        continue;
                    }

                    if (new_tail != tail)
                        self.runq_tail.store(new_tail, .release);
                    return first_task;
                }
            }
        }
        
        var run_queue = scheduler.run_queue.load(.relaxed);
        while (run_queue) |first_task| {
            run_queue = scheduler.run_queue.tryCompareAndSwap(
                first_task,
                null,
                .acquire,
                .relaxed,
            ) orelse {
                self.inject(first_task.next, tail, injected);
                return first_task;
            };
        }

        scheduler.platform.call(.{
            .worker = self,
            .polled = &polled,
            .intention = .last_resort,
        });

        if (polled.pop()) |first_task| {
            if (!polled.isEmpty()) {
                self.pushOverflow(polled);
                injected.* = true;
            }
            return first_task;
        }

        return null;
    }

    fn inject(self: *Worker, run_queue: ?*Task, tail: usize, injected: *bool) void {
        var new_tail = tail;
        var runq: ?*Task = run_queue orelse return;
        
        var remaining: usize = self.runq_buffer.len;
        while (remaining > 0) : (remaining -= 1) {
            const task = runq orelse break;
            runq = task.next;
            self.runq_buffer[new_tail % self.runq_buffer.len].store(task, .unordered);
            new_tail +%= 1;
        }

        injected.* = true;
        self.runq_tail.store(new_tail, .release);

        if (runq != null)
            self.runq_overflow.store(runq, .release);
    }

    fn run(self: *Worker, scheduler: *Scheduler) void {
        self.* = Worker{ .scheduler = scheduler };

        var active_queue = scheduler.active_queue.load(.relaxed);
        while (true) {
            self.active_next = active_queue;
            active_queue = scheduler.active_queue.tryCompareAndSwap(
                active_queue,
                &self,
                .release,
                .relaxed,
            ) orelse break;
        }

        self.runq_tick = @ptrToInt(&self);
        while (true) {
            const should_poll = switch (self.state) {
                .running, .waking => true,
                .suspended => @panic("worker trying to poll when suspended"),
                .stopping => false,
                .shutdown => break,
            };

            if (should_poll) {
                var injected = false;
                if (self.poll(scheduler, &injected)) |task| {
                    if (injected or self.state == .waking)
                        scheduler.resumeWorker(self.state == .waking);
                    self.state = .running;
                    self.runq_tick +%= 1;
                    resume task.frame;
                    continue;
                }
            }

            scheduler.suspendWorker(&self);
        }
    }
};

pub const Scheduler = extern struct {
    state: State = .running,
    idle_queue: ?*Worker = null,
    run_queue: Atomic(?*Task) = Atomic(?*Task).init(null),
    active_queue: Atomic(?*Worker) = Atomic(?*Worker).init(null),
    active_workers: Atomic(usize) = Atomic(usize).init(0),
    max_workers: usize,
    main_worker: ?*Worker = null,

    const State = enum(usize) {
        running,
        waking,
        notified,
        shutdown,
    };

    pub fn init(self: *Scheduler, num_threads: usize) void {
        self.* = Scheduler{ .max_workers = num_threads };
    }

    pub fn deinit(self: *Scheduler) void {
        self.* = undefined;
    }

    pub fn push(self: *Scheduler, batch: Batch) void {
        if (batch.isEmpty())
            return;
        
        batch.tail.next = self.run_queue;
        self.run_queue = batch.head;
    }

    pub fn run(self: *Scheduler) void {
        self.resumeWorker(false);
    }

    fn acquire(self: *Scheduler) void {
        self.platform.
    }

    fn release(self: *Scheduler) void {

    }

    pub fn shutdown(self: *Scheduler) void {
        const state = self.state.load(.relaxed);
        if (state == .shutdown)
            return;

        self.acquire();
        self.idle_lock.acquire();

        if (self.state == .shutdown) {
            self.idle_lock.release();
            return;
        }

        var idle_queue = self.idle_queue;
        self.idle_queue = null;
        @atomicStore(State, &self.state, .shutdown, .relaxed);
        self.idle_lock.release();

        while (idle_queue) |idle_worker| {
            const worker = idle_worker;
            idle_queue = worker.idle_next;
            
            worker.state = .stopping;
            worker.event.set();
        }
    }

    fn resumeWorker(self: *Scheduler, is_caller_waking: bool) void {
        const state = @atomicLoad(State, &self.state, .relaxed);
        if (state == .shutdown)
            return;
        if (!is_caller_waking and state == .notified)
            return;

        var spawn_retries: usize = 3;
        var is_waking = is_caller_waking;
        self.idle_lock.acquire();

        while (true) {
            if (self.state == .shutdown) {
                self.idle_lock.release();
                return;
            }

            if (!is_waking and self.state != .running) {
                if (self.state == .waking)
                    @atomicStore(State, &self.state, .notified, .relaxed);
                self.idle_lock.release();
                return;
            }

            if (self.idle_queue) |idle_worker| {
                const worker = idle_worker;
                self.idle_queue = worker.idle_next;
                @atomicStore(State, &self.state, .waking, .relaxed);
                self.idle_lock.release();

                if (worker.state != .suspended)
                    @panic("worker with invalid state when waking");
                worker.state = .waking;
                worker.event.set();
                return;
            }
            
            var active_workers = self.active_workers;
            if (active_workers < self.max_workers) {
                @atomicStore(usize, &self.active_workers, active_workers + 1, .relaxed);
                @atomicStore(State, &self.state, .waking, .relaxed);
                is_waking = true;
                self.idle_lock.release();

                if (Worker.spawn(self, active_workers == 0)) {
                    return;
                }

                self.idle_lock.acquire();
                active_workers = self.active_workers;
                @atomicStore(usize, &self.active_workers, active_workers - 1, .relaxed);
                if (self.state != .waking)
                    @panic("invalid scheduler state when trying to resume from failed spawn");

                spawn_retries -= 1;
                if (spawn_retries != 0)
                    continue;
            }

            @atomicStore(State, &self.state, if (is_waking) State.running else .notified, .relaxed);
            self.idle_lock.release();
            return;
        }
    }

    fn suspendWorker(self: *Scheduler, worker: *Worker) void {
        self.idle_lock.acquire();

        if (self.state == .shutdown) {
            worker.state = .stopping;
            worker.idle_next = self.idle_queue;
            self.idle_queue = worker;

            const is_main_worker = worker.thread == null;
            if (is_main_worker) {
                self.main_worker = worker;
            }
            
            const active_workers = self.active_workers;
            @atomicStore(usize, &self.active_workers, active_workers - 1, .relaxed);
            self.idle_lock.release();

            if (active_workers - 1 == 0) {
                const main_worker = self.main_worker orelse @panic("scheduler shutting down without main worker");
                main_worker.event.set();
            }

            worker.event.wait();

            if (is_main_worker) {
                if (@atomicLoad(usize, &self.active_workers, .relaxed) != 0)
                    @panic("remaining active workers when trying to shutdown all workers");

                while (self.idle_queue) |idle_worker| {
                    const shutdown_worker = idle_worker;
                    self.idle_queue = shutdown_worker.idle_next;

                    if (shutdown_worker.state != .stopping)
                        @panic("worker with invalid state when trying to shutdown");
                    shutdown_worker.state = .shutdown;

                    const thread = shutdown_worker.thread;
                    shutdown_worker.event.set();

                    if (thread) |thread_handle|
                        thread_handle.wait();
                }
            }

            if (worker.state != .shutdown)
                @panic("worker with invalid state when shutting down");
            return;
        }

        if (worker.state == .waking) {
            if (self.state == .notified) {
                @atomicStore(State, &self.state, .waking, .relaxed);
                self.idle_lock.release();
                return;
            } else {
                @atomicStore(State, &self.state, .running, .relaxed);
            }
        }

        worker.state = .suspended;
        worker.idle_next = self.idle_queue;
        self.idle_queue = worker;
        self.idle_lock.release();

        worker.event.wait();
        switch (worker.state) {
            .waking, .stopping => {},
            .suspended => @panic("worker resumed while still suspended"),
            .shutdown => @panic("worker resumed when already shutdown"),
            .running => @panic("worker resumed running instead of waking"),
        }
    }
};

pub const Platform = extern struct {
    callFn: fn(*Platform, Action) void,

    pub const Action = union(enum) {
        
    };

    pub fn call(self: *Platform, action: Action) void {
        return (self.callFn)(self, action);
    }
};

