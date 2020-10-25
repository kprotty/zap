const std = @import("std");

const Mutex = std.Mutex;
const AutoResetEvent = std.AutoResetEvent;
const Thread = std.Thread;

pub const Task = struct {
    next: ?*Task = undefined,
    frame: anyframe,

    pub fn init(frame: anyframe) Task {
        return Task{ .frame = frame };
    }

    pub fn schedule(self: *Task) void {
        Batch.from(self).schedule();
    }

    pub const runConcurrently = yield;
    pub fn yield() void {
        suspend {
            var task = Task.init(@frame());
            task.schedule();
        }
    }

    fn ReturnTypeOf(comptime asyncFn: anytype) type {
        return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
    }

    pub const Config = struct {
        threads: usize = 0,
    };

    pub fn run(config: Config, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        const Decorator = struct {
            fn entry(fn_args: anytype, task: *Task, result: *?ReturnTypeOf(asyncFn)) void {
                suspend task.* = Task.init(@frame());
                const value = @call(.{}, asyncFn, fn_args);
                suspend {
                    result.* = value;
                    const worker = Worker.current.?;
                    worker.scheduler.shutdown(worker); 
                }
            }
        };

        var task: Task = undefined;
        var result: ?ReturnTypeOf(asyncFn) = undefined;
        var frame = async Decorator.entry(args, &task, &result);

        const num_threads: usize = 
            if (std.builtin.single_threaded) 1
            else if (config.threads > 0) config.threads
            else Thread.cpuCount() catch 1;

        var scheduler = Scheduler{};
        scheduler.max_workers = num_threads;
        scheduler.run_queue.push(&task);
        scheduler.resumeWorker(.{ .is_main_thread = true });

        return result orelse error.Deadlocked;
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

        pub fn schedule(self: Batch) void {
            const worker = Worker.current orelse unreachable; // schedule() called when not in scheduler
            worker.schedule(self);
        }
    };

    const Scheduler = struct {
        lock: Mutex = Mutex{},
        run_queue: Batch = Batch{},
        idle_queue: ?*Worker = null,
        active_queue: ?*Worker = null,
        active_workers: usize = 0,
        max_workers: usize = 0,
        state: State = .ready,
        main_worker: *Worker = undefined,

        const State = enum {
            ready,
            waking,
            notified,
            shutdown,
        };

        fn resumeWorker(
            self: *Scheduler,
            context: struct {
                held: ?Mutex.Held = null,
                is_main_thread: bool = false,
                is_waking: bool = false,
            },
        ) void {
            var spawn_attempts: u8 = 3;
            var is_waking = context.is_waking;
            var held = context.held orelse self.lock.acquire();

            while (true) {
                if ((self.state == .shutdown) or (!is_waking and self.state != .ready)) {
                    if (self.state == .waking)
                        self.state = .notified;
                    held.release();
                    return;
                }

                if (self.idle_queue) |idle_worker| {
                    const worker = idle_worker;
                    self.idle_queue = worker.next;
                    self.state = .waking;

                    std.debug.assert(!std.builtin.single_threaded);
                    std.debug.assert(worker.state == .suspended);
                    worker.state = .waking;

                    held.release();
                    worker.event.set();
                    return;
                }

                if (self.active_workers == self.max_workers) {
                    self.state = if (is_waking) .ready else .notified;
                    held.release();
                    return;
                }

                @atomicStore(usize, &self.active_workers, self.active_workers + 1, .Monotonic);
                self.state = .waking;
                held.release();

                var spawn = Worker.Spawn{ .scheduler = self };
                if (std.builtin.single_threaded or context.is_main_thread) {
                    Worker.run(spawn);
                    return;
                }

                var spawner = Worker.Spawner{};
                spawn.spawner = &spawner;
                if (Thread.spawn(spawn, Worker.run)) |thread| {
                    spawner.thread = thread;
                    spawner.produced_event.set();
                    spawner.consumed_event.wait();
                    return;
                } else |_| {}

                held = self.lock.acquire();
                @atomicStore(usize, &self.active_workers, self.active_workers - 1, .Monotonic);
                is_waking = true;

                spawn_attempts -= 1;
                if (spawn_attempts == 0) {
                    if (self.state != .shutdown)
                        self.state = .ready;
                    held.release();
                    return;
                }
            }
        }

        fn suspendWorker(
            self: *Scheduler,
            context: struct {
                worker: *Worker,
                held: ?Mutex.Held,
            },
        ) void {
            const worker = context.worker;
            var held = context.held orelse self.lock.acquire();

            if (self.state == .shutdown) {
                worker.state = .stopping;
                worker.next = self.idle_queue;
                self.idle_queue = worker;
                const active_workers = self.active_workers;
                @atomicStore(usize, &self.active_workers, active_workers - 1, .Monotonic);
                held.release();

                if (active_workers == 1)
                    self.main_worker.event.set();

                worker.event.wait();
                if (worker.thread != null)
                    return;

                held = self.lock.acquire();
                var idle_queue = self.idle_queue;
                self.idle_queue = null;
                std.debug.assert(self.active_workers == 0);
                held.release();

                while (idle_queue) |idle_worker| {
                    const shutdown_worker = idle_worker;
                    idle_queue = shutdown_worker.next;
                    
                    std.debug.assert(shutdown_worker.state == .stopping);
                    shutdown_worker.state = .shutdown;

                    const thread = shutdown_worker.thread;
                    shutdown_worker.event.set();

                    if (thread) |thread_handle|
                        thread_handle.wait();
                }
                
                return;
            }

            if (worker.state == .waking) {
                if (self.state == .notified) {
                    self.state = .waking;
                    held.release();
                    return;
                } else {
                    self.state = .ready;
                }
            }

            worker.state = .suspended;
            worker.next = self.idle_queue;
            self.idle_queue = worker;
            held.release();
            
            worker.event.wait();
        }

        fn shutdown(self: *Scheduler, worker: *Worker) void {
            const held = self.lock.acquire();
            worker.state = .stopping;

            if (self.state == .shutdown) {
                held.release();
                return;
            }

            self.state = .shutdown;
            var idle_workers = self.idle_queue;
            self.idle_queue = null;
            held.release();

            while (idle_workers) |idle_worker| {
                const shutdown_worker = idle_worker;
                idle_workers = shutdown_worker.next;
                shutdown_worker.state = .stopping;
                shutdown_worker.event.set();
            }
        }
    };

    const Worker = struct {
        state: State = .waking,
        event: AutoResetEvent = AutoResetEvent{},
        scheduler: *Scheduler = undefined,
        thread: ?*Thread = null,
        next: ?*Worker = null,
        active_next: ?*Worker = null,
        active_target: ?*Worker = null,
        runq_head: usize = 0,
        runq_tail: usize = 0,
        runq_next: ?*Task = null,
        runq_buffer: [256]*Task = undefined,

        const State = enum {
            running,
            waking,
            suspended,
            stopping,
            shutdown,
        };

        const Spawn = struct {
            scheduler: *Scheduler,
            spawner: ?*Spawner = null,
        };

        const Spawner = struct {
            thread: *Thread = undefined,
            produced_event: AutoResetEvent = AutoResetEvent{},
            consumed_event: AutoResetEvent = AutoResetEvent{},
        };

        threadlocal var current: ?*Worker = null;

        fn run(spawn: Spawn) void {
            var self = Worker{};
            self.scheduler = spawn.scheduler;

            if (spawn.spawner) |spawner| {
                spawner.produced_event.wait();
                self.thread = spawner.thread;
                spawner.consumed_event.set();
            } else {
                self.scheduler.main_worker = &self;
            }

            const old_current = current;
            current = &self;
            defer current = old_current;

            var active_queue = @atomicLoad(?*Worker, &self.scheduler.active_queue, .Monotonic);
            while (true) {
                self.active_next = active_queue;
                active_queue = @cmpxchgWeak(
                    ?*Worker,
                    &self.scheduler.active_queue,
                    active_queue,
                    &self,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }

            while (true) {
                const should_poll = switch (self.state) {
                    .running, .waking => true,
                    .suspended => unreachable, // worker running when suspended
                    .stopping => false,
                    .shutdown => break, 
                };

                var held: ?Mutex.Held = null;
                if (should_poll) {
                    if (self.poll(&held)) |task| {
                        if (self.state == .waking) {
                            self.scheduler.resumeWorker(.{
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

                self.scheduler.suspendWorker(.{
                    .worker = &self,
                    .held = held,
                });
            }
        }

        fn schedule(self: *Worker, tasks: Batch) void {
            var batch = tasks;
            if (batch.isEmpty())
                return;

            var tail = self.runq_tail;
            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            while (!batch.isEmpty()) {

                if (@atomicLoad(?*Task, &self.runq_next, .Monotonic) == null) {
                    const task = batch.pop().?;
                    @atomicStore(?*Task, &self.runq_next, task, .Release);
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
                )) |updated_head| {
                    head = updated_head;
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

            const scheduler = self.scheduler;
            const held = scheduler.lock.acquire();
            scheduler.run_queue.pushMany(batch);
            scheduler.resumeWorker(.{ .held = held });
        }

        fn poll(self: *Worker, held: *?Mutex.Held) ?*Task {
            // TODO: if single-threaded, poll io-driver here
            
            var next = @atomicLoad(?*Task, &self.runq_next, .Monotonic);
            while (next) |task| {
                next = @cmpxchgWeak(
                    ?*Task,
                    &self.runq_next,
                    task,
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

            const scheduler = self.scheduler;
            var active_workers = @atomicLoad(usize, &scheduler.active_workers, .Monotonic);
            while (active_workers > 0) : (active_workers -= 1) {

                const target = self.active_target orelse blk: {
                    const target = @atomicLoad(?*Worker, &scheduler.active_queue, .Acquire);
                    self.active_target = target;
                    break :blk target orelse unreachable;
                };

                self.active_target = target.active_next;
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
                        const task = @atomicLoad(?*Task, &target.runq_next, .Monotonic) orelse break;
                        _ = @cmpxchgWeak(
                            ?*Task,
                            &target.runq_next,
                            task,
                            null,
                            .Acquire,
                            .Monotonic,
                        ) orelse return task;
                        continue;
                    }

                    const first_task = @atomicLoad(*Task, &target.runq_buffer[target_head % target.runq_buffer.len], .Unordered);
                    var new_target_head = target_head +% 1;
                    var new_tail = tail;
                    steal -= 1;

                    while (steal > 0) : (steal -= 1) {
                        const task = @atomicLoad(*Task, &target.runq_buffer[new_target_head % target.runq_buffer.len], .Unordered);
                        new_target_head +%= 1;
                        self.runq_buffer[new_tail % self.runq_buffer.len] = task;
                        new_tail +%= 1;
                    }

                    target_head = @cmpxchgWeak(
                        usize,
                        &target.runq_head,
                        target_head,
                        new_target_head,
                        .Monotonic,
                        .Monotonic,
                    ) orelse {
                        if (new_tail != tail)
                            @atomicStore(usize, &self.runq_tail, new_tail, .Release);
                        return first_task;
                    };
                }
            }

            held.* = scheduler.lock.acquire();
            const first_task = scheduler.run_queue.pop() orelse return null;

            var new_tail = tail;
            var remaining = self.runq_buffer.len;
            while (remaining > 0) : (remaining -= 1) {
                const task = scheduler.run_queue.pop() orelse break;
                @atomicStore(*Task, &self.runq_buffer[new_tail % self.runq_buffer.len], task, .Unordered);
                new_tail +%= 1;
            }

            if (new_tail != tail)
                @atomicStore(usize, &self.runq_tail, new_tail, .Release);
            return first_task;
        }
    };
};
