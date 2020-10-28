const std = @import("std");
const zap = @import("./zap.zig");

const Thread = std.Thread;
const AutoResetEvent = std.AutoResetEvent;

const Mutex = if (std.builtin.os.tag != .windows) std.Mutex else struct {
    locked: bool = false,

    fn acquire(self: *Mutex) Held {
        while (@atomicRmw(bool, &self.locked, .Xchg, true, .Acquire)) {
            _ = std.os.windows.kernel32.Sleep(1);
        }
        return Held{ .mutex = self };
    }

    const Held = struct {
        mutex: *Mutex,

        fn release(self: Held) void {
            @atomicStore(bool, &self.mutex.locked, false, .Release);
        }  
    };
};

pub const Task = struct {
    next: ?*Task = undefined,
    frame: anyframe,

    pub fn init(frame: anyframe) Task {
        return Task{ .frame = frame };
    }

    fn ReturnTypeOf(comptime asyncFn: anytype) type {
        return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
    }

    pub const RunConfig = struct {
        threads: ?usize = null,
    };

    pub fn run(config: RunConfig, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        const Decorator = struct {
            fn call(fn_args: anytype, task: *Task, result: *?ReturnTypeOf(asyncFn)) void {
                suspend task.* = Task.init(@frame());
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

        var scheduler: Scheduler = undefined;
        scheduler.init(num_threads);
        defer scheduler.deinit();

        scheduler.push(Batch.from(&task));
        scheduler.run();

        return result orelse error.Deadlocked;
    }

    pub fn yield() void {
        suspend {
            var task = Task.init(@frame());
            Batch.from(&task).schedule(.{ .use_lifo = false });
        }
    }

    pub fn schedule(self: *Task) void {
        Batch.from(self).schedule(.{});
    }

    pub fn scheduleNext(self: *Task) void {
        Batch.from(self).schedule(.{ .use_next = true });
    }

    pub const Batch = struct {
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

        pub fn pop(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }

        pub fn schedule(self: Batch, hints: Worker.ScheduleHints) void {
            if (self.isEmpty())
                return;

            const worker = Worker.getCurrent() orelse @panic("Batch.schedule when not inside scheduler");
            worker.schedule(self, hints);
        }
    };

    pub const Worker = struct {
        state: State = .waking,
        scheduler: *Scheduler,
        thread: ?*Thread,
        idle_next: ?*Worker = null,
        active_next: ?*Worker = null,
        target_worker: ?*Worker = null,
        event: AutoResetEvent = AutoResetEvent{},
        runq_head: usize = 0,
        runq_tail: usize = 0,
        runq_lifo: ?*Task = null,
        runq_next: ?*Task = null,
        runq_buffer: [256]*Task = undefined,

        const State = enum {
            waking,
            running,
            suspended,
            stopping,
            shutdown,
        };

        threadlocal var current: ?*Worker = null;

        pub fn getCurrent() ?*Worker {
            return Worker.current;
        }

        fn setCurrent(worker: ?*Worker) void {
            Worker.current = worker;
        }

        pub fn getScheduler(self: *Worker) *Scheduler {
            return self.scheduler;
        }

        pub const ScheduleHints = struct {
            use_lifo: bool = true,
            use_next: bool = false,
        };

        pub fn schedule(self: *Worker, tasks: Batch, hints: ScheduleHints) void {
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

            var tail = self.runq_tail;
            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);

            while (true) {
                if (hints.use_lifo and @atomicLoad(?*Task, &self.runq_lifo, .Monotonic) == null) {
                    @atomicStore(?*Task, &self.runq_lifo, batch.pop(), .Release);
                    if (batch.isEmpty())
                        break;

                    head = @atomicLoad(usize, &self.runq_head, .Monotonic);
                    continue;
                }

                var remaining = self.runq_buffer.len - (tail -% head);
                if (remaining > 0) {
                    while (remaining > 0) : (remaining -= 1) {
                        const task = batch.pop() orelse break;
                        @atomicStore(*Task, &self.runq_buffer[tail % self.runq_buffer.len], task, .Unordered);
                        tail +%= 1;
                    }

                    @atomicStore(usize, &self.runq_tail, tail, .Release);
                    if (batch.isEmpty())
                        break;

                    head = @atomicLoad(usize, &self.runq_head, .Monotonic);
                    continue;
                }

                const new_head = head +% (self.runq_buffer.len / 2);
                if (@cmpxchgWeak(
                    usize,
                    &self.runq_head,
                    head,
                    new_head,
                    .Monotonic,
                    .Monotonic,
                )) |updated| {
                    head = updated;
                    continue;
                }

                var overflowed = Batch{};
                while (head != new_head) : (head +%= 1) {
                    const task = self.runq_buffer[head % self.runq_buffer.len];
                    overflowed.push(task);
                }

                overflowed.pushMany(batch);
                batch = overflowed;
                break;
            }

            const scheduler = self.getScheduler();
            const held = scheduler.lock.acquire();
            scheduler.run_queue.pushMany(batch);
            scheduler.resumeWorker(.{ .held = held });
        }

        fn poll(self: *Worker, scheduler: *Scheduler, held: *?Mutex.Held) ?*Task {
            // TODO: if single-threaded, poll for io/timers (non-blocking)

            if (self.runq_next) |next| {
                const task = next;
                self.runq_next = null;
                return task;
            }

            var lifo = @atomicLoad(?*Task, &self.runq_lifo, .Monotonic);
            while (lifo) |task| {
                lifo = @cmpxchgWeak(
                    ?*Task,
                    &self.runq_lifo,
                    lifo,
                    null,
                    .Monotonic,
                    .Monotonic,
                ) orelse return task;
            }

            var tail = self.runq_tail;
            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            while (tail != head) {
                head = @cmpxchgWeak(
                    usize,
                    &self.runq_head,
                    head,
                    head +% 1,
                    .Monotonic,
                    .Monotonic,
                ) orelse return self.runq_buffer[head % self.runq_buffer.len];
            }

            var steal_attempts: usize = 1;
            while (steal_attempts > 0) : (steal_attempts -= 1) {
                
                var active_workers = @atomicLoad(usize, &scheduler.active_workers, .Monotonic);
                while (active_workers > 0) : (active_workers -= 1) {

                    const target = self.target_worker orelse blk: {
                        const target = @atomicLoad(?*Worker, &scheduler.active_queue, .Acquire);
                        self.target_worker = target;
                        break :blk (target orelse @panic("no active workers when trying to steal"));
                    };

                    self.target_worker = target.active_next;
                    if (target == self)
                        continue;

                    var target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                    while (true) {
                        const target_tail = @atomicLoad(usize, &target.runq_tail, .Acquire);

                        const target_size = target_tail -% target_head;
                        if (target_size > target.runq_buffer.len) {
                            target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                            continue;
                        }

                        var steal = target_size - (target_size / 2);
                        if (steal == 0) {
                            if (@atomicLoad(?*Task, &target.runq_lifo, .Monotonic)) |task| {
                                _ = @cmpxchgWeak(
                                    ?*Task,
                                    &target.runq_lifo,
                                    task,
                                    null,
                                    .Acquire,
                                    .Monotonic,
                                ) orelse return task;
                            } else {
                                break;
                            }

                            target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                            continue;
                        }

                        const first_task = @atomicLoad(*Task, &target.runq_buffer[target_head % target.runq_buffer.len], .Unordered);
                        var new_target_head = target_head +% 1;
                        var new_tail = tail;
                        steal -= 1;

                        while (steal > 0) : (steal -= 1) {
                            const task = @atomicLoad(*Task, &target.runq_buffer[new_target_head % target.runq_buffer.len], .Unordered);
                            new_target_head +%= 1;
                            @atomicStore(*Task, &self.runq_buffer[new_tail % self.runq_buffer.len], task, .Unordered);
                            new_tail +%= 1;
                        }

                        if (@cmpxchgWeak(
                            usize,
                            &target.runq_head,
                            target_head,
                            new_target_head,
                            .Monotonic,
                            .Monotonic,
                        )) |updated| {
                            target_head = updated;
                            continue;
                        }

                        if (new_tail != tail)
                            @atomicStore(usize, &self.runq_tail, new_tail, .Release);
                        return first_task;
                    }
                }
            }

            held.* = scheduler.lock.acquire();
            if (scheduler.run_queue.pop()) |first_task| {
                var new_tail = tail;
                var remaining: usize = self.runq_buffer.len;

                while (remaining > 0) : (remaining -= 1) {
                    const task = scheduler.run_queue.pop() orelse break;
                    @atomicStore(*Task, &self.runq_buffer[new_tail % self.runq_buffer.len], task, .Unordered);
                    new_tail +%= 1;
                }

                if (new_tail != tail)
                    @atomicStore(usize, &self.runq_tail, new_tail, .Release);
                return first_task;
            }

            // TODO: if single-threaded, poll for io/timers (blocking)
            return null;
        }

        const SpawnInfo = struct {
            scheduler: *Scheduler,
            thread: ?*Thread = null,
            thread_event: AutoResetEvent = AutoResetEvent{},
            spawn_event: AutoResetEvent = AutoResetEvent{},
        };

        fn spawn(scheduler: *Scheduler, use_caller_thread: bool) bool {
            var spawn_info = SpawnInfo{ .scheduler = scheduler };

            if (std.builtin.single_threaded or use_caller_thread) {
                spawn_info.thread_event.set();
                Worker.run(&spawn_info);
                return true;
            }

            spawn_info.thread = Thread.spawn(&spawn_info, Worker.run) catch return false;
            spawn_info.thread_event.set();
            spawn_info.spawn_event.wait();
            return true;
        }

        fn run(spawn_info: *SpawnInfo) void {
            const scheduler = spawn_info.scheduler;
            spawn_info.thread_event.wait();
            const thread = spawn_info.thread;
            spawn_info.spawn_event.set();

            var self = Worker{
                .scheduler = scheduler,
                .thread = thread,
            };

            const old_current = Worker.getCurrent();
            Worker.setCurrent(&self);
            defer Worker.setCurrent(old_current);

            var active_queue = @atomicLoad(?*Worker, &scheduler.active_queue, .Monotonic);
            while (true) {
                self.active_next = active_queue;
                active_queue = @cmpxchgWeak(
                    ?*Worker,
                    &scheduler.active_queue,
                    active_queue,
                    &self,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }

            while (true) {
                const should_poll = switch (self.state) {
                    .running, .waking => true,
                    .suspended => @panic("worker trying to poll when suspended"),
                    .stopping => false,
                    .shutdown => break,
                };

                var held: ?Mutex.Held = null;
                if (should_poll) {
                    if (self.poll(scheduler, &held)) |task| {
                        if (self.state == .waking) {
                            scheduler.resumeWorker(.{
                                .is_waking = true,
                                .held = held,
                            });
                        } else if (held) |h| {
                            h.release();
                        }
                        self.state = .running;
                        resume task.frame;
                        continue;
                    }
                }

                scheduler.suspendWorker(.{
                    .worker = &self,
                    .held = held,
                });
            }
        }
    };

    pub const Scheduler = struct {
        state: State = .running,
        lock: Mutex = Mutex{},
        run_queue: Batch = Batch{},
        idle_queue: ?*Worker = null,
        active_queue: ?*Worker = null,
        active_workers: usize = 0,
        max_workers: usize,
        main_worker: ?*Worker = null,

        const State = enum {
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
            self.run_queue.pushMany(batch);
        }

        pub fn run(self: *Scheduler) void {
            self.resumeWorker(.{});
        }

        pub fn shutdown(self: *Scheduler) void {
            const held = self.lock.acquire();

            if (self.state == .shutdown) {
                held.release();
                return;
            }

            var idle_queue = self.idle_queue;
            self.idle_queue = null;
            self.state = .shutdown;
            held.release();

            while (idle_queue) |idle_worker| {
                const worker = idle_worker;
                idle_queue = worker.idle_next;
                
                worker.state = .stopping;
                worker.event.set();
            }
        }

        const ResumeContext = struct {
            is_waking: bool = false,
            held: ?Mutex.Held = null,
        };

        fn resumeWorker(self: *Scheduler, context: ResumeContext) void {
            var spawn_retries: usize = 3;
            var is_waking = context.is_waking;
            var held = context.held orelse self.lock.acquire();

            while (true) {
                if (self.state == .shutdown) {
                    held.release();
                    return;
                }

                if (!is_waking and self.state != .running) {
                    if (self.state == .waking)
                        self.state = .notified;
                    held.release();
                    return;
                }

                if (self.idle_queue) |idle_worker| {
                    const worker = idle_worker;
                    self.idle_queue = worker.idle_next;
                    self.state = .waking;
                    held.release();

                    if (worker.state != .suspended)
                        @panic("worker with invalid state when waking");
                    worker.state = .waking;
                    worker.event.set();
                    return;
                }
                
                var active_workers = self.active_workers;
                if (active_workers < self.max_workers) {
                    @atomicStore(usize, &self.active_workers, active_workers + 1, .Monotonic);
                    self.state = .waking;
                    is_waking = true;
                    held.release();

                    if (Worker.spawn(self, active_workers == 0)) {
                        return;
                    }

                    held = self.lock.acquire();
                    active_workers = self.active_workers;
                    @atomicStore(usize, &self.active_workers, active_workers - 1, .Monotonic);
                    if (self.state != .waking)
                        @panic("invalid scheduler state when trying to resume from failed spawn");

                    spawn_retries -= 1;
                    if (spawn_retries != 0)
                        continue;
                }

                self.state = if (is_waking) .running else .notified;
                held.release();
                return;
            }
        }

        const SuspendContext = struct {
            worker: *Worker,
            held: ?Mutex.Held,
        };

        fn suspendWorker(self: *Scheduler, context: SuspendContext) void {
            var held = context.held orelse self.lock.acquire();

            if (self.state == .shutdown) {
                context.worker.state = .stopping;
                context.worker.idle_next = self.idle_queue;
                self.idle_queue = context.worker;

                const is_main_worker = context.worker.thread == null;
                if (is_main_worker) {
                    self.main_worker = context.worker;
                }
                
                const active_workers = self.active_workers;
                @atomicStore(usize, &self.active_workers, active_workers - 1, .Monotonic);
                held.release();

                if (active_workers - 1 == 0) {
                    const main_worker = self.main_worker orelse @panic("scheduler shutting down without main worker");
                    main_worker.event.set();
                }

                context.worker.event.wait();

                if (is_main_worker) {
                    if (@atomicLoad(usize, &self.active_workers, .Monotonic) != 0)
                        @panic("remaining active workers when trying to shutdown all workers");

                    while (self.idle_queue) |idle_worker| {
                        const worker = idle_worker;
                        self.idle_queue = worker.idle_next;

                        if (worker.state != .stopping)
                            @panic("worker with invalid state when trying to shutdown");
                        worker.state = .shutdown;

                        const thread = worker.thread;
                        worker.event.set();

                        if (thread) |thread_handle|
                            thread_handle.wait();
                    }
                }

                if (context.worker.state != .shutdown)
                    @panic("worker with invalid state when shutting down");
                return;
            }

            if (context.worker.state == .waking) {
                if (self.state == .notified) {
                    self.state = .waking;
                    held.release();
                    return;
                } else {
                    self.state = .running;
                }
            }

            context.worker.state = .suspended;
            context.worker.idle_next = self.idle_queue;
            self.idle_queue = context.worker;
            held.release();

            context.worker.event.wait();
            switch (context.worker.state) {
                .waking, .stopping => {},
                .suspended => @panic("worker resumed while still suspended"),
                .shutdown => @panic("worker resumed when already shutdown"),
                .running => @panic("worker resumed running instead of waking"),
            }
        }
    };
};
