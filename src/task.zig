const std = @import("std");
const zap = @import("./zap.zig");
const core = zap.core;

pub const Task = extern struct {
    task: core.executor.Task = core.executor.Task{},
    runnable: usize,

    pub const Callback = fn(*Task) callconv(.C) void;

    pub fn init(callback: Callback) Task {
        return Task{ .runnable = @ptrToInt(callback) | 1 };
    }

    pub fn initAsync(frame: anyframe) Task {
        return Task{ .runnable = @ptrToInt(frame) };
    }

    fn ReturnTypeOf(comptime asyncFn: anytype) type {
        return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
    }

    pub const Config = struct {
        threads: usize = 0,
    };

    pub fn runAsync(config: Config, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        return runAsyncWith(config, asyncFn, args, false);
    }

    pub fn runAsyncForever(config: Config, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        return runAsyncWith(config, asyncFn, args, true);
    }

    fn runAsyncWith(config: Config, comptime asyncFn: anytype, args: anytype, comptime forever: bool) !ReturnTypeOf(asyncFn) {
        const Decorator = struct {
            fn entry(fn_args: anytype, task: *Task, result: *?ReturnTypeOf(asyncFn)) void {
                suspend task.* = Task.initAsync(@frame());
                const value = @call(.{}, asyncFn, fn_args);
                suspend {
                    result.* = value;
                    if (!forever) {
                        Worker.getCurrent().getScheduler().shutdown();
                    }
                }
            }
        };

        var task: Task = undefined;
        var result: ?ReturnTypeOf(asyncFn) = undefined;
        var frame = async Decorator.entry(args, &task, &result);

        task.run(config);

        return result orelse error.Deadlocked;
    }

    pub fn run(self: *Task, config: Config) void {
        const num_threads: usize = 
            if (std.builtin.single_threaded) 1
            else if (config.threads > 0) config.threads
            else Thread.cpuCount();

        Scheduler.run(num_threads, Batch.from(self));
    }

    pub fn shutdown() void {
        Worker.getCurrent().getScheduler().shutdown();
    }

    pub fn schedule(self: *Task) void {
        Batch.from(self).schedule();
    }

    pub fn scheduleNext(self: *Task) void {
        Batch.from(self).scheduleNext();
    }

    pub fn runConcurrentlyAsync() void {
        suspend {
            var task = Task.initAsync(@frame());
            task.schedule();
        }
    }

    pub fn yieldAsync() void {
        suspend {
            var task = Task.initAsync(@frame());
            Worker.getCurrent().worker.schedule(Batch.from(&task).batch, .{});
        }
    }

    pub const Batch = extern struct {
        batch: core.executor.Task.Batch = core.executor.Task.Batch{},

        pub fn from(task: *Task) Batch {
            return Batch{ .batch = core.executor.Task.Batch.from(&task.task) };
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

        pub fn pop(self: *Batch) ?*Task {
            const task = self.batch.pop() orelse return null;
            return @fieldParentPtr(Task, "task", task);
        }

        pub fn schedule(self: Batch) void {
            self.scheduleToWorker(false);
        }

        pub fn scheduleNext(self: Batch) void {
            self.scheduleToWorker(true);
        }

        fn scheduleToWorker(self: Batch, use_next: bool) void {
            Worker.getCurrent().worker.schedule(self.batch, .{
                .use_next = use_next,
                .use_lifo = true,
            });
        }
    };
    
    const Thread = zap.runtime.Thread;
    const Lock = zap.runtime.sync.Lock;
    const AutoResetEvent = zap.runtime.sync.AutoResetEvent;

    pub const Scheduler = struct {
        lock: Lock,
        has_worker: bool,
        platform: Platform,
        scheduler: core.executor.Scheduler,

        pub fn run(num_threads: usize, initial_batch: Batch) void {
            var self: Scheduler = undefined;

            self.lock = Lock{};
            self.has_worker = false;
            self.platform = Platform{};
            self.scheduler.init(&self.platform.platform, num_threads);

            self.scheduler.schedule(initial_batch.batch);
            std.debug.assert(self.has_worker);
        }

        pub fn schedule(self: *Scheduler, batch: Batch) void {
            self.scheduler.schedule(batch.batch);
        }

        pub fn shutdown(self: *Scheduler) void {
            self.scheduler.shutdown();
        }
    };

    pub const Worker = struct {
        event: AutoResetEvent,
        worker: core.executor.Worker,
        thread: ?Thread.Handle,

        fn run(thread: ?Thread.Handle, scheduler_ptr: usize) void {
            var self: Worker = undefined;
            self.event = AutoResetEvent{};
            self.thread = thread;

            const scheduler = @intToPtr(*Scheduler, scheduler_ptr);
            const is_main_thread = !scheduler.has_worker;
            scheduler.has_worker = true;

            const old_current = Worker.tryGetCurrent();
            Worker.setCurrent(&self);
            defer Worker.setCurrent(old_current);

            self.worker.run(&scheduler.scheduler, is_main_thread);
        }

        threadlocal var current: ?*Worker = null;

        fn setCurrent(worker: ?*Worker) void {
            Worker.current = worker;
        }

        pub fn tryGetCurrent() ?*Worker {
            return Worker.current;
        }

        pub fn getCurrent() *Worker {
            return Worker.tryGetCurrent() orelse {
                unreachable; // Worker.getCurrent() called when not inside a Scheduler thread
            };
        }

        pub fn getScheduler(self: *Worker) *Scheduler {
            const scheduler = self.worker.getScheduler();
            return @fieldParentPtr(Scheduler, "scheduler", scheduler);
        }

        pub fn schedule(self: *Worker, batch: Batch) void {
            self.worker.schedule(batch.batch, .{ .use_lifo = true });
        }
    };

    const Platform = struct {
        platform: core.executor.Platform = core.executor.Platform{ .callFn = call },

        fn call(self: *core.executor.Platform, action: core.executor.Platform.Action) void {
            switch (action) {
                .spawned => |spawned| {
                    const scheduler = @fieldParentPtr(Scheduler, "scheduler", spawned.scheduler);
                    if (std.builtin.single_threaded or !scheduler.has_worker) {
                        spawned.spawned = true;
                        Worker.run(null, @ptrToInt(scheduler));
                    } else {
                        spawned.spawned = Thread.spawn(@ptrToInt(scheduler), Worker.run);
                    }
                },
                .joined => |joined| {
                    const worker = @fieldParentPtr(Worker, "worker", joined.worker);
                    const thread = worker.thread;
                    worker.event.set();
                    if (thread) |thread_handle|
                        Thread.join(thread_handle);
                },
                .resumed => |core_worker| {
                    const worker = @fieldParentPtr(Worker, "worker", core_worker);
                    worker.event.set();
                },
                .suspended => |core_worker| {
                    const worker = @fieldParentPtr(Worker, "worker", core_worker);
                    worker.event.wait();
                },
                .acquired => |core_scheduler| {
                    const scheduler = @fieldParentPtr(Scheduler, "scheduler", core_scheduler);
                    scheduler.lock.acquire();
                },
                .released => |core_scheduler| {
                    const scheduler = @fieldParentPtr(Scheduler, "scheduler", core_scheduler);
                    scheduler.lock.release();
                },
                .executed => |executed| {
                    const task = blk: {
                        @setRuntimeSafety(false);
                        break :blk @fieldParentPtr(Task, "task", executed.task);
                    };

                    if (task.runnable & 1 != 0) {
                        const callback = blk: {
                            @setRuntimeSafety(false);
                            break :blk @intToPtr(Callback, task.runnable & ~@as(usize, 1));
                        };
                        return (callback)(task);
                    }

                    const frame = blk: {
                        @setRuntimeSafety(false);
                        break :blk @intToPtr(anyframe, task.runnable);
                    };
                    resume frame;
                },
            }
        } 
    };
};