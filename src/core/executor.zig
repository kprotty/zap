const std = @import("std");
const core = @import("../zap.zig").core;

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

        pub fn pop(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }
    };
};

pub const Platform = struct {
    callFn: fn(*Platform, Action) void,

    pub const Action = union(enum) {
        spawned: Spawned,
        joined: Joined,
        resumed: Resumed,
        suspended: Suspended,
        acquired: *Scheduler,
        released: *Scheduler,
        polled: Polled,
        executed: Executed,

        pub const Spawned = struct {
            scheduler: *Scheduler,
            spawned: *bool,
            was_first: bool,
        };

        pub const Joined = struct {
            scheduler: *Scheduler,
            worker: *Worker,
        };

        pub const Suspended = struct {
            worker: *Worker,
            intention: Intention,

            pub const Intention = enum {
                last,
                waiting,
                shutdown,
            };
        };

        pub const Resumed = struct {
            worker: *Worker,
            intention: Intention,

            pub const Intention = enum {
                first,
                waking,
                shutdown,
            };
        };

        pub const Executed = struct {
            worker: *Worker,
            task: *Task,
        };

        pub const Polled = struct {
            worker: *Worker,
            batch: *Task.Batch,
            intention: Intention,

            pub const Intention = enum {
                eager,
                last_resort,
            };
        };
    };

    pub fn call(self: *Platform, action: Action) void {
        return (self.callFn)(self, action);
    }
};

pub const Scheduler = extern struct {
    platform: *Platform,
    run_queue: Task.Batch = Task.Batch{},
    idle_queue: ?*Worker = null,
    running_workers: Atomic(usize) = Atomic(usize).init(0),
    active_queue: Atomic(?*Worker) = Atomic(?*Worker).init(null),
    active_workers: Atomic(usize) = Atomic(usize).init(0),
    max_workers: usize,
    state: State = .ready,
    main_worker: *Worker = undefined,

    const State = extern enum {
        ready,
        waking,
        notified,
        shutdown,
    };

    pub fn init(self: *Scheduler, platform: *Platform, max_workers: usize) void {
        self.* = Scheduler{
            .platform = platform,
            .max_workers = max_workers,
        };
    }

    pub fn schedule(self: *Scheduler, batch: Task.Batch) void {
        if (batch.isEmpty())
            return;

        self.run_queue.pushMany(batch);
        self.resumeWorker(.{});
    }

    fn acquire(self: *Scheduler) void {
        self.platform.call(.{ .acquired = self });
    }

    fn release(self: *Scheduler) void {
        self.platform.call(.{ .released = self });
    }

    fn resumeWorker(
        self: *Scheduler,
        context: struct {
            is_acquired: bool = false,
            is_waking: bool = false,
        },
    ) void {
        var spawn_attempts: u8 = 3;
        var is_waking = context.is_waking;
        if (!context.is_acquired)
            self.acquire();

        while (true) {
            if ((self.state == .shutdown) or (!is_waking and self.state != .ready)) {
                if (self.state == .waking)
                    self.state = .notified;
                self.release();
                return;
            }

            if (self.idle_queue) |idle_worker| {
                const worker = idle_worker;
                self.idle_queue = worker.next;
                self.state = .waking;

                if (worker.state == .suspended) {
                    worker.state = .waking;
                } else {
                    unreachable; // worker with invalid state when being resumed
                }

                const running_workers = self.running_workers.get();
                self.running_workers.store(running_workers + 1, .relaxed);
                const was_first = running_workers == 0;

                self.release();
                worker.notify(if (was_first) .first else .waking);
                return;
            }

            const active_workers = self.active_workers.get();
            if (active_workers == self.max_workers) {
                self.state = if (is_waking) .ready else .notified;
                self.release();
                return;
            }

            const running_workers = self.running_workers.get();
            self.running_workers.store(running_workers + 1, .relaxed);
            const was_first = running_workers == 0;

            self.active_workers.store(active_workers + 1, .relaxed);
            self.state = .waking;
            self.release();

            var did_spawn = false;
            self.platform.call(.{
                .spawned = .{
                    .scheduler = self,
                    .spawned = &did_spawn,
                    .was_first = was_first,
                },
            });

            if (did_spawn)
                return;

            self.acquire();
            self.active_workers.store(self.active_workers.get() - 1, .relaxed);
            self.running_workers.store(self.running_workers.get() - 1, .relaxed);
            is_waking = true;

            spawn_attempts -= 1;
            if (spawn_attempts == 0) {
                if (self.state != .shutdown)
                    self.state = .ready;
                self.release();
                return;
            }
        }
    }

    fn suspendWorker(
        self: *Scheduler,
        context: struct {
            worker: *Worker,
            is_acquired: bool,
        },
    ) void {
        const worker = context.worker;
        if (!context.is_acquired)
            self.acquire();

        if (self.state == .shutdown) {
            worker.state = .stopping;
            worker.next = self.idle_queue;
            self.idle_queue = worker;

            const active_workers = self.active_workers.get();
            self.active_workers.store(active_workers - 1, .relaxed);
            self.release();

            if (active_workers == 1) {
                self.main_worker.notify(.shutdown);
            }

            worker.wait(.shutdown);
            if (!worker.isMainWorker())
                return;

            var idle_queue = blk: {
                self.acquire();
                defer self.release();

                const idle_queue = self.idle_queue;
                self.idle_queue = null;
                if (self.active_workers.get() != 0)
                    unreachable; // active workers remaining when joining workers

                break :blk idle_queue;
            };

            while (idle_queue) |idle_worker| {
                const shutdown_worker = idle_worker;
                idle_queue = shutdown_worker.next;
                
                if (shutdown_worker.state == .stopping) {
                    shutdown_worker.state = .shutdown;
                } else {
                    unreachable; // worker had invalid state when trying to join/shutdown
                }

                self.platform.call(.{
                    .joined = .{
                        .scheduler = self,
                        .worker = shutdown_worker,
                    },
                });
            }
            
            return;
        }

        if (worker.state == .waking) {
            if (self.state == .notified) {
                self.state = .waking;
                self.release();
                return;
            } else {
                self.state = .ready;
            }
        }

        const running_workers = self.running_workers.get();
        self.running_workers.store(running_workers - 1, .relaxed);
        const was_last = running_workers == 1;

        worker.state = .suspended;
        worker.next = self.idle_queue;
        self.idle_queue = worker;
        self.release();
        
        worker.wait(if (was_last) .last else .waiting);
    }

    pub fn shutdown(self: *Scheduler) void {
        self.acquire();

        if (self.state == .shutdown) {
            self.release();
            return;
        }

        self.state = .shutdown;
        self.running_workers.store(0, .relaxed);
        
        var idle_workers = self.idle_queue;
        self.idle_queue = null;
        self.release();

        while (idle_workers) |idle_worker| {
            const shutdown_worker = idle_worker;
            idle_workers = shutdown_worker.next;
            shutdown_worker.state = .stopping;
            shutdown_worker.notify(.shutdown);
        }
    }
};

pub const Worker = extern struct {
    state: State = .waking,
    scheduler: usize,
    next: ?*Worker = null,
    active_next: ?*Worker = null,
    active_target: ?*Worker = null,
    runq_next: ?*Task = null,
    runq_head: Atomic(usize) = Atomic(usize).init(0),
    runq_tail: Atomic(usize) = Atomic(usize).init(0),
    runq_lifo: Atomic(?*Task) = Atomic(?*Task).init(null),
    runq_buffer: [256]Atomic(*Task) = undefined,

    const State = extern enum {
        running,
        waking,
        suspended,
        stopping,
        shutdown,
    };

    pub fn run(self: *Worker, scheduler: *Scheduler, is_main_worker: bool) void {
        self.* = Worker{ .scheduler = @ptrToInt(scheduler) | @boolToInt(is_main_worker) };
        if (is_main_worker)
            scheduler.main_worker = self;

        var active_queue = scheduler.active_queue.load(.relaxed);
        while (true) {
            self.active_next = active_queue;
            active_queue = scheduler.active_queue.tryCompareAndSwap(
                active_queue,
                self,
                .release,
                .relaxed,
            ) orelse break;
        }

        while (true) {
            const should_poll = switch (self.state) {
                .running, .waking => true,
                .suspended => unreachable, // worker running when suspended
                .stopping => false,
                .shutdown => break, 
            };

            var has_lock = false;
            if (should_poll) {
                if (self.poll(&has_lock, scheduler)) |task| {
                    if (self.state == .waking) {
                        scheduler.resumeWorker(.{
                            .is_waking = true,
                            .is_acquired = has_lock,
                        });
                    } else if (has_lock) {
                        scheduler.release();
                    }

                    self.state = .running;
                    scheduler.platform.call(.{
                        .executed = .{
                            .worker = self,
                            .task = task,
                        },
                    });
                    continue;
                }
            }

            scheduler.suspendWorker(.{
                .worker = self,
                .is_acquired = has_lock,
            });
        }
    }

    pub fn getScheduler(self: Worker) *Scheduler {
        @setRuntimeSafety(false);
        return @intToPtr(*Scheduler, self.scheduler & ~@as(usize, 1));
    }

    fn isMainWorker(self: Worker) bool {
        return self.scheduler & 1 != 0;
    }

    fn wait(self: *Worker, intention: Platform.Action.Suspended.Intention) void {
        self.getScheduler().platform.call(.{
            .suspended = .{
                .worker = self,
                .intention = intention,
            },
        });
    }

    fn notify(self: *Worker, intention: Platform.Action.Resumed.Intention) void {
        self.getScheduler().platform.call(.{
            .resumed = .{
                .worker = self,
                .intention = intention,
            },
        });
    }

    pub const ScheduleHints = struct {
        use_lifo: bool = false,
        use_next: bool = false,
    };

    pub fn schedule(self: *Worker, tasks: Task.Batch, hints: ScheduleHints) void {
        if (self.push(tasks, hints)) |overflowed| {
            const scheduler = self.getScheduler();
            scheduler.acquire();
            scheduler.run_queue.pushMany(overflowed);
            scheduler.resumeWorker(.{ .is_acquired = true });
        }   
    }

    fn push(self: *Worker, tasks: Task.Batch, hints: ScheduleHints) ?Task.Batch {
        var batch = tasks;
        if (batch.isEmpty())
            return null;

        if (hints.use_next) {
            if (self.runq_next) |old_next|
                batch.push(old_next);
            self.runq_next = batch.pop();
            if (batch.isEmpty())
                return null;
        }

        var tail = self.runq_tail.get();
        var head = self.runq_head.load(.relaxed);
        while (true) {
            if (batch.isEmpty())
                return null;

            if (hints.use_lifo and self.runq_lifo.load(.relaxed) == null) {
                const task = batch.pop().?;
                self.runq_lifo.store(task, .release);
                head = self.runq_head.load(.relaxed);
                continue;
            }

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
            )) |updated_head| {
                head = updated_head;
                continue;
            }

            var overflowed = Task.Batch{};
            while (head != new_head) : (head +%= 1) {
                const task = self.runq_buffer[head % self.runq_buffer.len].get();
                overflowed.push(task);
            }

            overflowed.pushMany(batch);
            return overflowed;
        }
    }

    fn poll(self: *Worker, has_lock: *bool, scheduler: *Scheduler) ?*Task {
        var polled = Task.Batch{};
        scheduler.platform.call(.{
            .polled = .{
                .worker = self,
                .batch = &polled,
                .intention = .eager,
            },
        });

        if (polled.pop()) |first_task| {
            if (self.push(polled, .{ .use_lifo = true })) |overflowed| {
                scheduler.acquire();
                scheduler.run_queue.pushMany(overflowed);
                scheduler.resumeWorker(.{
                    .is_waking = self.state == .waking,
                    .is_acquired = true,
                });
                scheduler.release();
                self.state = .running;
            }
            return first_task;
        }
        
        if (self.runq_next) |next| {
            const task = next;
            self.runq_next = null;
            return task;
        }

        var next = self.runq_lifo.load(.relaxed);
        while (next) |task| {
            next = self.runq_lifo.tryCompareAndSwap(
                task,
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

        var active_workers = scheduler.active_workers.load(.relaxed);
        while (active_workers > 0) : (active_workers -= 1) {

            const target = self.active_target orelse blk: {
                const target = scheduler.active_queue.load(.acquire);
                self.active_target = target;
                break :blk target orelse unreachable;
            };

            self.active_target = target.active_next;
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
                    const task = target.runq_lifo.load(.relaxed) orelse break;
                    _ = target.runq_lifo.tryCompareAndSwap(
                        task,
                        null,
                        .acquire,
                        .relaxed,
                    ) orelse return task;
                    continue;
                }

                const first_task = target.runq_buffer[target_head % target.runq_buffer.len].load(.unordered);
                var new_target_head = target_head +% 1;
                var new_tail = tail;
                steal -= 1;

                while (steal > 0) : (steal -= 1) {
                    const task = target.runq_buffer[new_target_head % target.runq_buffer.len].load(.unordered);
                    new_target_head +%= 1;
                    self.runq_buffer[new_tail % self.runq_buffer.len].store(task, .unordered);
                    new_tail +%= 1;
                }

                target_head = target.runq_head.tryCompareAndSwap(
                    target_head,
                    new_target_head,
                    .relaxed,
                    .relaxed,
                ) orelse {
                    if (new_tail != tail)
                        self.runq_tail.store(new_tail, .release);
                    return first_task;
                };
            }
        }

        scheduler.acquire();
        if (scheduler.run_queue.pop()) |first_task| {
            var new_tail = tail;
            var remaining = self.runq_buffer.len;
            while (remaining > 0) : (remaining -= 1) {
                const task = scheduler.run_queue.pop() orelse break;
                self.runq_buffer[new_tail % self.runq_buffer.len].store(task, .unordered);
                new_tail +%= 1;
            }

            if (new_tail != tail)
                self.runq_tail.store(new_tail, .release);

            has_lock.* = true;
            return first_task;
        }

        scheduler.release();
        scheduler.platform.call(.{
            .polled = .{
                .worker = self,
                .batch = &polled,
                .intention = .last_resort,
            },
        });

        if (polled.pop()) |first_task| {
            var new_tail = tail;
            var remaining = self.runq_buffer.len;
            while (remaining > 0) : (remaining -= 1) {
                const task = polled.pop() orelse break;
                self.runq_buffer[new_tail % self.runq_buffer.len].store(task, .unordered);
                new_tail +%= 1;
            }

            if (new_tail != tail)
                self.runq_tail.store(new_tail, .release);
            if (!polled.isEmpty()) {
                scheduler.acquire();
                scheduler.run_queue.pushMany(polled);
                has_lock.* = true;
            }

            return first_task;
        }

        return null;
    }
};
