// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const platform = @import("./platform.zig");
const core = @import("../zap.zig").core.executor;

pub const Scheduler = struct {
    pub const Config = union(enum) {
        uma: void,
        smp: Smp,
        numa: Numa,

        pub const Smp = struct {
            max_threads: usize = std.math.maxInt(usize),
            stack_size: usize = 1 * 1024 * 1024,
        };

        pub const Numa = struct {
            cluster: Node.Cluster,
            start_index: usize,
        };
    };

    pub const RunAsyncError = RunError || error {
        AsyncDeadlocked,
    };

    pub fn runAsyncSmp(
        smp_config: Config.Smp,
        comptime func: anytype,
        func_args: anytype,
    ) RunAsyncError!@TypeOf(func).ReturnType {
        return runAsync(Config{ .smp = smp_config }, func, func_args);
    }

    pub fn runAsyncNuma(
        numa_config: Config.Numa,
        comptime func: anytype,
        func_args: anytype,
    ) RunAsyncError!@TypeOf(func).ReturnType {
        return runAsync(Config{ .numa = numa_config }, func, func_args);
    }

    pub fn runAsync(
        config: Config,
        comptime func: anytype,
        func_args: anytype,
    ) RunAsyncError!@TypeOf(func).ReturnType {
        const ArgsType = @TypeOf(func_args);
        const ReturnType = @TypeOf(func).ReturnType;
        
        const Wrapper = struct {
            fn call(args: ArgsType, task: *Task, result: *?ReturnType) void {
                suspend task.* = Task.init(@frame());
                const ret_value = @call(.{}, func, args);
                suspend result.* = ret_value;
            }
        };

        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.call(func_args, &task, &result);

        try Scheduler.run(config, &task.runnable);

        return result orelse RunAsyncError.AsyncDeadlocked;
    }

    pub const RunError = core.Scheduler.StartError || error {
        OutOfNodeMemory,
    };

    pub fn runSmp(
        smp_config: Config.Smp,
        noalias runnable: *Task.Runnable,
    ) RunError!void {
        return self.run(Config{ .smp = smp_config }, runnable);
    }

    pub fn runNuma(
        numa_config: Config.Numa,
        noalias runnable: *Task.Runnable,
    ) RunError!void {
        return self.run(Config{ .numa = numa_config }, runnable);
    }

    pub fn run(
        config: Config,
        noalias runnable: *Task.Runnable,
    ) RunError!void {
        switch (config) {
            .numa => |numa_config| {
                return runWithNuma(numa_config, runnable);
            },
            .uma => {
                var node: Node = undefined;
                var workers = [_]Worker{undefined};
                node.init(&platform.NumaNode.getTopology()[0], &workers, 0);

                var cluster = Node.Cluster{};
                cluster.push(&node);
                const numa_config = Config.Numa{
                    .cluster = cluster,
                    .start_index = 0,
                };

                return runWithNuma(numa_config, runnable);
            },
            .smp => |smp_config| {
                const worker_offset = std.mem.alignForward(@sizeOf(Node), @alignOf(Worker));

                var cluster = Node.Cluster{};
                defer {
                    var nodes = cluster.iter();
                    while (nodes.next()) |node| {
                        const num_workers = node.getWorkers().len;
                        const memory_ptr = @ptrCast([*]align(std.mem.page_size) u8, @alignCast(std.mem.page_size, node));
                        const memory_len = worker_offset + (@sizeOf(Worker) * num_workers);
                        node.numa_node.free(memory_ptr[0..memory_len]);
                    }
                }

                var remaining_workers = std.math.max(1, smp_config.max_threads);
                if (std.builtin.single_threaded)
                    remaining_workers = 1;

                const topology = platform.NumaNode.getTopology();
                for (topology) |*numa_node| {
                    var num_workers = (numa_node.cpu_end + 1) - (numa_node.cpu_begin);
                    num_workers = std.math.min(num_workers, remaining_workers);
                    remaining_workers -= num_workers;

                    const bytes = worker_offset + (@sizeOf(Worker) * num_workers);
                    const memory = numa_node.alloc(bytes) catch return RunError.OutOfNodeMemory;
                    const node = @ptrCast(*Node, @alignCast(@alignOf(Node), &memory[0]));
                    const workers_ptr = @ptrCast([*]Worker, @alignCast(@alignOf(Worker), &memory[worker_offset]));

                    const workers = workers_ptr[0..num_workers];
                    node.init(numa_node, workers, smp_config.stack_size);
                    cluster.push(node);
                }

                const numa_config = Config.Numa{
                    .cluster = cluster,
                    .start_index = (@ptrToInt(&cluster) * 31) % topology.len,
                };
                return runWithNuma(numa_config, runnable);
            },
        }
    }

    fn runWithNuma(
        numa_config: Config.Numa,
        noalias runnable: *Task.Runnable,
    ) core.Scheduler.StartError!void {
        var scheduler: core.Scheduler = undefined;
        scheduler.init(numa_config.cluster.inner);
        defer scheduler.deinit();

        const starting_worker = try scheduler.start(
            numa_config.start_index,
            runnable,
        );

        Thread.run(null, starting_worker);

        var thread_handles = scheduler.finish();
        while (thread_handles.next()) |thread_handle| {
            const thread = @ptrCast(*platform.Thread, @alignCast(@alignOf(platform.Thread), thread_handle));
            thread.join();
        }
    }
};

pub const Node = struct {
    pub const Cluster = struct {
        inner: core.Node.Cluster = core.Node.Cluster{},
        len: usize = 0,

        pub fn push(
            noalias self: *Cluster,
            noalias node: *Node,
        ) void {
            self.inner.pushBack(&node.inner);
            self.len += 1;
        }

        pub fn iter(self: Cluster) Iter {
            return Iter.from(self.inner.iter());
        }
    };

    pub const Iter = struct {
        inner: core.Node.Iter,

        fn from(inner: core.Node.Iter) Iter {
            return Iter{ .inner = inner };
        }

        pub fn next(noalias self: *Iter) ?*Node {
            const inner_node = self.inner.next() orelse return null;
            return @fieldParentPtr(Node, "inner", inner_node);
        }
    };

    inner: core.Node,
    numa_node: *platform.NumaNode,
    stack_size: usize,

    pub fn init(
        noalias self: *Node,
        noalias numa_node: *platform.NumaNode,
        workers: []Worker,
        stack_size: usize,
    ) void {
        self.inner.init(workers);
        self.numa_node = numa_node;
        self.stack_size = platform.Thread.getStackSize(stack_size);
    }

    pub fn getWorkers(noalias self: *Node) []Worker {
        return self.inner.getWorkers();
    }

    pub fn iter(noalias self: *Node) Iter {
        return Iter.from(self.inner.iter());
    }
};

pub const Worker = core.Worker;

pub const Thread = struct {
    threadlocal var current: ?*Thread = null;

    pub fn getCurrent() *Thread {
        return current orelse {
            std.debug.panic("Batch.schedule() when not running in scheduler", .{});
        };
    }

    inner: core.Thread,
    event: platform.Event,

    fn run(
        noalias handle: ?*platform.Thread,
        noalias worker: *Worker,
    ) void {
        var self = Thread{
            .inner = undefined,
            .event = undefined,
        };

        self.inner.init(worker, @ptrCast(core.Thread.Handle, handle));
        defer self.inner.deinit();

        self.event.init();
        defer self.event.deinit();

        const node = @fieldParentPtr(Node, "inner", self.inner.getNode());
        platform.Thread.bindCurrentToNodeAffinity(node, blk: {
            const offset = @ptrToInt(worker) - @ptrToInt(node.getWorkers().ptr);
            const worker_index = @divFloor(offset, @sizeOf(Worker));
            break :blk worker_index;
        });

        Thread.current = &self;
        while (true) {
            switch (self.inner.poll()) {
                .run => |runnable| {
                    runnable.run(&self.inner);
                },
                .scheduled => |schedule| {
                    self.scheduleThreadAction(schedule);
                },
                .shutdown => {
                    break;
                },
                .suspended => |last_thread| {
                    if (last_thread) {
                        var inner_threads = node.inner.getScheduler().shutdown();
                        while (inner_threads.next()) |inner_thread| {
                            const thread = @fieldParentPtr(Thread, "inner", inner_thread);
                            if (thread != &self)
                                thread.event.notify();
                        }
                        break;
                    } else {
                        self.event.wait();
                    }
                },
            }
        }
    }

    fn scheduleThreadAction(
        noalias self: *Thread,
        schedule: core.Thread.Schedule,
    ) void {
        switch (schedule.action) {
            .resumed => |inner_thread| {
                const thread = @fieldParentPtr(Thread, "inner", inner_thread);
                thread.event.notify();
            },
            .spawned => |worker| {
                const node = @fieldParentPtr(Node, "inner", self.inner.getNode());
                const handle = platform.Thread.spawn(node, Thread.run, worker) catch |err| {
                    self.inner.undoSchedule(schedule);
                    return;
                };
            },
        }
    }
};

pub const Task = struct {
    runnable: Runnable,
    frame: anyframe,

    pub const Runnable = core.Task;

    pub const Priority = Runnable.Priority;

    pub fn init(frame: anyframe) Task {
        return Task{
            .runnable = Runnable.init(@"resume"),
            .frame = frame,
        };
    }

    fn @"resume"(
        noalias runnable: *Runnable,
        noalias thread: *core.Thread,
    ) callconv(.C) void {
        const task = @fieldParentPtr(Task, "runnable", runnable);
        return resume task.frame;
    }

    pub const Batch = extern struct {
        inner: Runnable.Batch = Runnable.Batch{},

        pub fn from(priority: Priority, noalias task: *Task) Batch {
            return fromRunnable(priority, &task.runnable);
        }

        pub fn fromRunnable(priority: Priority, noalias runnable: *Runnable) Batch {
            runnable.setPriority(priority);
            return Batch{
                .inner = Runnable.Batch.from(runnable),
            };
        }

        pub fn push(noalias self: *Batch, priority: Priority, noalias task: *Task) void {
            return self.pushRunnable(priority, &task.runnable);
        }

        pub fn pushRunnable(noalias self: *Batch, priority: Priority, noalias runnable: *Runnable) void {
            return self.pushMany(Batch.fromRunnable(priority, runnable));
        }

        pub fn pushMany(noalias self: *Batch, batch: Batch) void {
            return self.inner.pushBackMany(batch.inner);
        }

        pub fn schedule(self: Batch) void {
            const thread = Thread.getCurrent();
            if (thread.inner.schedule(self.inner)) |schedule_action| {
                thread.scheduleThreadAction(schedule_action);
            }
        }
    };

    pub fn schedule(noalias self: *Task, priority: Priority) void {
        Batch.from(priority, self).schedule();
    }

    pub fn yield(priority: Priority) void {
        var task = Task.init(@frame());
        suspend {
            task.schedule(priority);
        }
    }

    pub fn run(
        comptime async_func: anytype,
        func_args: anytype,
    ) Scheduler.RunAsyncError!@TypeOf(async_func).ReturnType {
        const config = Scheduler.Config{ .smp = Scheduler.Config.Smp{} };
        return Scheduler.runAsync(config, async_func, func_args);
    }
};