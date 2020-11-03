const std = @import("std");
const zap = @import("../zap.zig");

const executor = zap.core.executor;
const Atomic = zap.core.sync.atomic.Atomic;
const OsFutex = zap.runtime.sync.OsFutex;
const Condition = zap.core.sync.Condition;

const Thread = std.Thread;
const ResetEvent = struct {
    futex: OsFutex = OsFutex{},
    updated: Atomic(bool) = Atomic(bool).init(false),
    condition: Condition = Condition{ .isMetFn = poll },

    fn poll(condition: *Condition) bool {
        const self = @fieldParentPtr(ResetEvent, "condition", condition);
        return self.updated.swap(true, .acquire);
    }

    fn reset(self: *ResetEvent) void {
        self.updated.set(false);
    }

    fn wait(self: *ResetEvent) void {
        if (!self.futex.wait(null, &self.condition))
            @panic("ResetEvent timed out without a deadline");
    }

    fn set(self: *ResetEvent) void {
        if (self.updated.swap(true, .release))
            self.futex.wake();
    }
};

pub const Task = extern struct {
    task: executor.Task = executor.Task{},
    runnable: usize,

    pub const Callback = fn(*Task, *Worker) callconv(.C) void;

    pub fn init(callback: Callback) Task {
        return Task{ .runnable = @ptrToInt(callback) | 1 };
    }

    pub fn initAsync(frame: anyframe) Task {
        return Task{ .runnable = @ptrToInt(frame) };
    }

    pub fn execute(self: *Task, worker: *Worker) void {
        @setRuntimeSafety(false);
        const runnable = self.runnable;
        
        if (runnable & 1 != 0) {
            const callback = @intToPtr(Callback, runnable & ~@as(usize, 1));
            return (callback)(self, worker);
        }

        const frame = @intToPtr(anyframe, runnable);
        resume frame;
    }

    fn ReturnTypeOf(comptime asyncFn: anytype) type {
        return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
    }

    pub const RunConfig = struct {
        threads: ?usize = null,
    };

    pub fn runAsync(config: RunConfig, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        return runAsyncShutdown(true, config, asyncFn, args);
    }

    pub fn runAsyncForever(config: RunConfig, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        return runAsyncShutdown(false, config, asyncFn, args);
    }

    fn runAsyncShutdown(comptime shutdown_after: bool, config: RunConfig, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        const Decorator = struct {
            fn call(fn_args: anytype, task: *Task, result: *?ReturnTypeOf(asyncFn)) void {
                suspend task.* = Task.initAsync(@frame());
                const res = @call(.{}, asyncFn, fn_args);
                suspend {
                    result.* = res;
                    if (shutdown_after) {
                        Worker.getCurrent().?.getScheduler().shutdown();
                    }
                }
            }
        };

        var task: Task = undefined;
        var result: ?ReturnTypeOf(asyncFn) = null;
        var frame = async Decorator.call(args, &task, &result);

        try task.run(config);

        return result orelse error.Deadlocked;
    }

    pub fn yieldAsync() void {
        suspend {
            var task = Task.initAsync(@frame());
            Batch.from(&task).schedule(.{ .use_lifo = false });
        }
    }

    pub fn runConcurrentlyAsync() void {
        suspend {
            var task = Task.initAsync(@frame());
            Batch.from(&task).schedule(.{ .use_lifo = true });
        }
    }

    pub fn schedule(self: *Task) void {
        Batch.from(self).schedule(.{});
    }

    pub fn scheduleNext(self: *Task) void {
        Batch.from(self).schedule(.{ .use_next = true });
    }

    pub fn run(self: *Task, config: RunConfig) !void {
        return Batch.from(self).run(config);
    }

    pub const Batch = extern struct {
        batch: executor.Task.Batch = executor.Task.Batch{},

        pub fn from(task: *Task) Batch {
            return Batch{ .batch = executor.Task.Batch.from(&task.task) };
        }

        pub fn isEmpty(self: Batch) bool {
            return self.batch.isEmpty();
        }

        pub fn push(self: *Batch, task: *Task) void {
            self.pushMany(Batch.from(task));
        }

        pub fn pushMany(self: *Batch, other: Batch) void {
            self.batch.pushMany(other.batch);
        }

        pub fn pushFront(self: *Batch, task: *Task) void {
            self.pushFrontMany(Batch.from(task));
        }

        pub fn pushFrontMany(self: *Batch, other: Batch) void {
            self.batch.pushFrontMany(other.batch);
        }

        pub fn pop(self: *Batch) ?*Task {
            const task = self.batch.pop() orelse return null;
            return @fieldParentPtr(Task, "task", task);
        }

        pub fn schedule(self: Batch, hints: Worker.ScheduleHints) void {
            if (self.isEmpty())
                return;

            const worker = Worker.getCurrent() orelse @panic("Batch.schedule when not inside scheduler");
            worker.schedule(self, hints);
        }

        pub fn run(self: Batch, config: RunConfig) !void {
            if (self.isEmpty())
                return;

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

            return scheduler.run(self);
        }
    };

    pub const Worker = struct {
        worker: executor.Worker,
        thread: ?*Thread,
        event: ResetEvent,

        fn run(spawn_info: *SpawnInfo) void {
            const scheduler = spawn_info.scheduler;
            spawn_info.thread_event.wait();

            const thread = spawn_info.thread;
            spawn_info.spawn_event.set();

            var self: Worker = undefined;
            self.worker.init(&scheduler.scheduler, thread == null);
            self.thread = thread;
            self.event = ResetEvent{};

            const old_current = Worker.getCurrent();
            Worker.setCurrent(&self);
            defer Worker.setCurrent(old_current);

            while (true) {
                switch (self.worker.poll()) {
                    .executed => |core_task| {
                        const task = @fieldParentPtr(Task, "task", core_task);
                        task.execute(&self);
                    },
                    .suspended => |intent| {
                        if (intent == .retry)
                            continue;
                        self.event.wait();
                        self.event.reset();
                    },
                    .shutdown => break,
                }
            }
        }

        threadlocal var current: ?*Worker = null;

        pub fn getCurrent() ?*Worker {
            return Worker.current;
        }

        fn setCurrent(worker: ?*Worker) void {
            Worker.current = worker;
        }

        pub fn getScheduler(self: *Worker) *Scheduler {
            const core_scheduler = self.worker.getScheduler();
            return @fieldParentPtr(Scheduler, "scheduler", core_scheduler);
        }

        pub const ScheduleHints = executor.Worker.ScheduleHints;

        pub fn schedule(self: *Worker, tasks: Batch, hints: ScheduleHints) void {
            return self.worker.schedule(tasks.batch, hints);
        }

        const SpawnInfo = struct {
            scheduler: *Scheduler,
            thread: ?*Thread = null,
            thread_event: ResetEvent = ResetEvent{},
            spawn_event: ResetEvent = ResetEvent{},
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
    };

    pub const Scheduler = struct {
        scheduler: executor.Scheduler,
        platform: executor.Platform,

        pub fn init(self: *Scheduler, num_threads: usize) void {
            self.platform = executor.Platform{ .callFn = handlePlatformCall };
            self.scheduler.init(&self.platform, num_threads);
        }

        pub fn deinit(self: *Scheduler) void {
            self.scheduler.deinit();
            self.* = undefined;
        }

        pub fn run(self: *Scheduler, batch: Batch) void {
            self.scheduler.run(batch.batch);
        }

        pub fn shutdown(self: *Scheduler) void {
            self.scheduler.shutdown();   
        }

        fn handlePlatformCall(platform: *executor.Platform, action: executor.Platform.Action) void {
            switch (action) {
                .polled => |polled| {
                    // TODO: poll for io/timers in single threaded
                },
                .spawned => |spawned| {
                    const scheduler = @fieldParentPtr(Scheduler, "scheduler", spawned.scheduler);
                    spawned.succeeded.* = Worker.spawn(scheduler, spawned.intent == .first);
                },
                .resumed => |resumed| {
                    const worker = @fieldParentPtr(Worker, "worker", resumed.worker);

                    var thread: ?*Thread = null;
                    if (resumed.intent == .join)
                        thread = worker.thread;

                    worker.event.set();
                    if (thread) |thread_ptr| {
                        thread_ptr.wait();
                    }
                },
            }
        }
    };

    pub const AsyncFutex = struct {
        task: Atomic(*Task) = undefined,

        pub fn wait(self: *AsyncFutex, deadline: ?*Timestamp, condition: *Condition) bool {
            var task = Task.initAsync(@frame());

            suspend {
                self.task.store(&task, .unordered);
                if (condition.isMet())
                    task.scheduleNext();    
            }

            // TODO: integrate timers
            return true;
        }

        pub fn wake(self: *AsyncFutex) void {
            const task = self.task.load(.unordered);
            task.schedule();
        }

        pub const Timestamp = OsFutex.Timestamp;

        pub fn timestamp(current: *Timestamp) void {
            return OsFutex.timestamp(current);
        }

        pub fn timeSince(t1: *Timestamp, t2: *Timestamp) u64 {
            return OsFutex.timeSince(t1, t2);
        }
    };
};
