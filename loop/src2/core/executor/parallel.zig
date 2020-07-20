const std = @import("std");
const executor = @import("./executor.zig");

pub fn ParallelExecutor(comptime Platform: type) {
    return struct {
        const Executor = executor.Executor(Scheduler);

        pub const Scheduler = extern struct {
            const CACHE_LINE = Platform.CACHE_LINE;
            const LOCAL_TASK_BUFFER_SIZE = Platform.WORKER_SHARED_BUFFER_SIZE;

            running_workers: usize align(Platform.CACHE_LINE),
            active_nodes: usize align(Platform.CACHE_LINE),
            stop_event: Platform.AutoResetEvent,
            has_main_thread: bool,
            platform: *Platform,

            pub fn run(
                platform: *Platform,
                nodes: []*Node,
                start_node: usize,
                start_task: *Task,
            ) void {
                if (nodes.len == 0)
                    return;

                var self = Scheduler{
                    .running_workers = 0,
                    .active_nodes = 0,
                    .stop_event = undefined,
                    .has_main_thread = false,
                    .platform = platform,
                };

                self.stop_event.init();
                for (nodes) |node|
                    node.init();

                defer {
                    self.stop_event.deinit();
                    std.debug.assert(@atomicLoad(usize, &self.running_workers, .Monotonic) == 0);
                    std.debug.assert(@atomicLoad(usize, &self.active_nodes, .Monotonic) == 0);
                    for (nodes) |node|
                        node.deinit();
                };

                const executor_task = &task.executor_task;
                const executor_nodes = @ptrCast([*]*Executor.Node, nodes.ptr)[0..nodes.len];
                Executor.Scheduler.run(&self, executor_nodes, start_node, executor_task);
                if (self.has_main_thread)
                    self.stop_event.wait();
            }

            pub fn nodes(self: *Scheduler) []*Node {
                const executor_nodes = @fieldParentPtr(Executor.Scheduler, "platform", self).nodes();
                return @ptrCast([*]*Node, executor_nodes.ptr)[0..executor_nodes.len];
            }

            fn emit(
                noalias self: *Scheduler,
                event: Executor.Worker.Event,
                noalias executor_worker: *Executor.Worker,
            ) void {
                const worker = @fieldParentPtr(Worker, "executor_worker", executor_worker);
                const node = worker.node();

                switch (event) {
                    .Run => |started| {
                        var is_main_thread = !self.has_main_thread;
                        if (is_main_thread)
                            self.has_main_thread = true;

                        if (is_main_thread) {
                            self.running_workers = 1;
                            node.active_workers = 1;
                            self.active_nodes = 1;
                        } else {
                            _ = @atomicRmw(usize, &self.running_workers, .Add, 1, .Monotonic);
                            if (@atomicRmw(usize, &node.active_workers, .Add, 1, .Monotonic) == 0)
                                _ = @atomicRmw(usize, &self.active_nodes, .Add, 1, .Monotonic);
                        }
                        
                        started.* = false;
                        if (self.platform.runWorker(worker, is_main_thread)) {
                            started.* = true;
                            return;
                        }

                        if (is_main_thread) {
                            self.running_workers = 0;
                            node.active_workers = 0;
                            self.active_nodes = 0;
                        } else {
                            _ = @atomicRmw(usize, &self.running_workers, .Sub, 1, .Monotonic);
                            if (@atomicRmw(usize, &node.active_workers, .Sub, 1, .Monotonic) == 1)
                                _ = @atomicRmw(usize, &self.active_nodes, .Sub, 1, .Monotonic);
                        }
                    },
                    .Poll => |task_ptr| {
                        task_ptr.* = null;
                        const task = worker.poll(node, self.platform) orelse return;
                        if (!worker.tryScheduleByAffinity(task))
                            task_ptr.* = &task.executor_task;
                    },
                    .Resume => {
                        if (worker.executor_worker.state() != .Stopping) {
                            if (@atomicRmw(usize, &node.active_workers, .Add, 1, .Monotonic) == 0)
                                _ = @atomicRmw(usize, &self.active_nodes, .Add, 1, .Monotonic);
                        }
                        worker.event.set();
                    },
                    .Suspend => {
                        if (@atomicRmw(usize, &node.active_workers, .Sub, 1, .Monotonic) == 1) {
                            if (@atomicRmw(usize, &self.active_nodes, .Sub, 1, .Monotonic) == 1) {
                                @atomicStore(Executor.Worker.State, &worker.executor_worker.state, .Stopping, .Monotonic);
                                node.executor_node.scheduler.shutdown();
                                return;
                            }
                        }
                        worker.event.wait();
                    },
                    .Execute => |executor_task| {
                        var task = @fieldParentPtr(Task, "executor_task", executor_task);
                        (task.run_fn_ptr.*)(task, worker);
                        worker.tasks_ran +%= 1;
                    },
                }
            }
        };

        pub const Node = extern struct {
            executor_node: Executor.Node,
            active_workers: usize align(Platform.CACHE_LINE),
            poll_guard: Executor.Guard align(Platform.CACHE_LINE),

            fn init(self: *Node) void {
                self.poll_guard.init();
                self.active_workers = 0;
            }

            fn deinit(self: *Node) void {
                self.poll_guard.deinit();
                std.debug.assert(@atomicLoad(usize, &node.active_workers, .Monotonic) == 0);
            }

            pub fn prepare(self: *Node, workers: []*Worker) void {
                const workers_ptr = @alignCast(@alignOf([*]*Executor.Worker, workers.ptr));
                self.executor_node.prepare(workers_ptr[0..workers.len]);
            }

            pub fn scheduler(self: Node) *Scheduler {
                return self.executor_node.scheduler.platform;
            }

            pub fn workers(self: Node) []*Worker {
                const executor_workers = self.executor_node.workers();
                return @ptrCast([*]*Worker, executor_workers.ptr)[0..executor_workers.len];
            }

            pub fn schedule(self: *Node, batch: Task.Queue) void {
                self.executor_node.push(batch);
                self.resumeWorker();
            }

            fn resumeWorker(self: *Node) void {
                const nodes = self.scheduler().nodes;
                const platform = self.scheduler().platform;
                
                var node_iter: Platform.NodeIter = undefined;
                node_iter.init(self, nodes, platform);
                defer node_iter.deinit();

                var attempts: usize = 0;
                while (attempts < nodes.len) : (attempts += 1) {
                    const node = node_iter.next() orelse break;
                    if (node.executor_node.tryResumeWorker())
                        return;
                }
            }
        };

        pub const Worker = extern struct {
            executor_worker: Executor.Worker,
            event: Platform.AutoResetEvent,
            tasks_ran: usize,

            pub fn run(self: *Worker) void {
                self.event.init();
                self.tasks_ran = 0;

                self.executor_worker.run();

                self.event.deinit();
                const scheduler = self.executor_worker.node.platform;
                if (@atomicRmw(usize, &scheduler.running_workers, .Sub, 1, .Monotonic) == 1)
                    scheduler.stop_event.set();
            }

            pub fn node(self: Worker) *Node {
                return @fieldParentPtr(Node, "executor_node", &self.executor_worker.node);
            }

            pub fn schedule(self: *Worker, batch: Task.Queue) void {
                if (batch.len == 0)
                    return;

                if (batch.len != 1)
                    return self.node().schedule(batch);
                
                const task = batch.pop().?;
                if (self.tryScheduleByAffinity(task))
                    return;

                const side = switch (task.priority()) {
                    .Low => return self.node().schedule(Task.Queue.from(task)),
                    .Normal => Executor.Task.Queue.Side.Back,
                    .High => Executor.Task.Queue.Side.Front, 
                };

                while (self.executor_worker.push(&task.executor_task, side)) |overflow|
                    self.executor_worker.node.push(overflow);
                self.node().resumeWorker();
            }

            fn tryScheduleByAffinity(noalias self: *Worker, noalias task: *Task) bool {
                switch (task.affinity()) {
                    .Worker => |task_worker| {
                        if (task_worker != self) {
                            const wrapped = Executor.Task.Queue.from(&task.executor_task);
                            task_worker.executor_worker.pushLocal(wrapped);
                            _ = task_worker.executor_worker.tryResume();
                            return true;
                        }
                    },
                    .Node => |task_node| {
                        if (task_node != self.node()) {
                            const wrapped = Executor.Task.Queue.from(&task.executor_task);
                            task_node.executor_node.pushLocal(wrapped);
                            _ = task_node.executor_node.tryResumeWorker();
                            return true;
                        }
                    },
                    .Scheduler => {},
                }
                return false;
            }

            const PollFrequency = union(enum) {
                Worker: usize,
                Global: usize,
                Local: usize,
                SharedFront: usize,
                SharedBack: usize,
            };

            fn pollFrequencyOrder() []PollFrequency {
                comptime var frequencies = [_]PollFrequency{
                    PollFrequency{ .Worker = Platform.WORKER_POLL_WORKER_FREQUENCY },
                    PollFrequency{ .Global = Platform.WORKER_POLL_GLOBAL_FREQUENCY },
                    PollFrequency{ .Local = Platform.WORKER_POLL_LOCAL_FREQUENCY },
                    PollFrequency{ .SharedFront = Platform.WORKER_POLL_SHARED_FRONT_FREQUENCY },
                    PollFrequency{ .SharedBack = Platform.WORKER_POLL_SHARED_BACK_FREQUENCY },
                };
                std.sort(PollFrequency, frequencies[0..], PollFrequency.lessThan);
                return frequencies;
            }

            fn poll(
                noalias self: *Worker,
                noalias node: *Node,
                noalias platform: *Platform,
            ) ?*Task {
                const iteration = self.tasks_ran;

                if (iteration > 0) {
                    inline for (comptime pollFrequencyOrder()) |poll_frequency| {
                        switch (poll_frequency) {
                            .Worker => |frequency| {
                                if (iteration % frequency == 0)
                                    if (platform.pollWorker(self, false)) |task|
                                        return task;
                            },
                            .Global => |frequency| {
                                if (iteration % frequency == 0)
                                    if (self.pollNode(node, 1)) |task|
                                        return task;
                            },
                            .Local => |frequency| {
                                if (iteration % frequency == 0)
                                    if (self.pollLocal()) |task|
                                        return task;
                            },
                            .SharedFront => |frequency| {
                                if (iteration % frequency == 0)
                                    if (self.pollShared(.Front)) |task|
                                        return task;
                            },
                            .SharedBack => |frequency| {
                                if (iteration % frequency == 0)
                                    if (self.pollShared(.Back)) |task|
                                        return task;
                            },
                        }
                    }                    

                    if (self.pollLocal()) |task|
                        return task;

                    if (self.pollShared(.Front)) |task|
                        return task;

                    if (platform.pollWorker(self, false)) |task|
                        return task;
                }

                while (true) {
                    if (self.steal(node, platform)) |task|
                        return task;

                    if (platform.pollWorker(self, true)) |task|
                        return task;

                    _ = node.executor_node.trySuspendWorker(&self.executor_worker);
                    switch (self.executor_worker.state()) {
                        .Stopping => return null,
                        .Searching => continue,
                        .Running => unreachable,
                        .Notified => unreachable,
                        .Suspended => unreachable,
                        .Stopped => unreachable,
                    }
                }
            }

            fn steal(
                noalias self: *Worker,
                noalias node: *Node,
                noalias platform: *Platform,
            ) ?*Task {
                const nodes = node.scheduler().nodes();
                var node_iter: Platform.NodeIter = undefined;
                var worker_iter: Platform.WorkerIter = undefined;

                try_steal: while (true) {
                    var attempts: usize = 0;
                    while (attempts < Platform.STEAL_ATTEMPTS) : (attempts += 1) {
                        node_iter.init(node, nodes, platform);
                        defer node_iter.deinit();

                        var node_attempts: usize = 0;
                        while (node_attempts < nodes.len) : (node_attempts += 1) {
                            const target_node = node_iter.next() orelse break;
                            if (self.pollNode(target_node, std.math.maxInt(usize))) |task|
                                return task;

                            const workers = node.workers();
                            worker_iter.init(self, workers, platform);
                            defer worker_iter.deinit();

                            var worker_attempts: usize = 0;
                            while (worker_attempts < workers.len) : (worker_attempts += 1) {
                                const target_worker = worker_iter.next() orelse break;
                                if (self.pollWorker(target_worker)) |task|
                                    return task;
                            }
                        }
                    }

                    for (nodes) |some_node| {
                        if (some_node == node and !node.executor_node.isLocalEmpty())
                            continue :try_steal;
                        if (!some_node.executor_node.isEmpty())
                            continue :try_steal;
                        for (target_node.workers()) |some_worker| {
                            if (some_worker == self and !self.executor_worker.isLocalEmpty())
                                continue :try_steal;
                            if (!some_worker.executor_worker.isEmpty())
                                continue :try_steal;
                        }
                    }

                    return null;
                }
            }

            fn pollLocal(self: *Worker) ?*Task {
                const executor_task = self.executor_worker.popLocal() orelse return null;
                return @fieldParentPtr(Task, "executor_task", executor_task);
            }

            fn pollShared(self: *Worker, comptime side: Executor.Task.Queue.Side) ?*Task {
                const executor_task = self.executor_worker.pop(side) orelse return null;
                return @fieldParentPtr(Task, "executor_task", executor_task);
            }

            fn pollWorker(noalias self: *Worker, noalias target: *Worker) ?*Task {
                const executor_task = self.executor_worker.steal(&target.executor_worker) orelse return null;
                return @fieldParentPtr(Task, "executor_task", executor_task);
            }

            fn pollNode(noalias self: *Worker, noalias node: *Node, max: usize) ?*Task {
                if (!node.poll_guard.tryAcquire())
                    return null;
                defer node.poll_guard.release();

                const pos = @atomicLoad(usize, &self.executor_worker.runq_pos.pos, .Monotonic);
                const head = Executor.BoundedPos.decodeHead(pos);
                const tail = Executor.BoundedPos.decodeTail(pos);
                var new_tail = tail;

                var tasks_found: usize = 0;
                var first_task: ?*Task = null;
                poll_node: while (tasks_found < max) : (tasks_found += 1) {

                    const task = blk: {
                        var attempts: usize = 0;
                        while (attempts < 4) : (attempts += 1) {
                            var executor_task: ?*Executor.Task = null;
                            if (self.node() == node)
                                executor_task = node.executor_node.popLocal();
                            if (executor_task == null)
                                executor_task = node.executor_node.pop();
                            if (executor_task) |t|
                                break :blk @fieldParentPtr(Task, "executor_task", t);
                        }
                        break :poll_node;
                    };

                    if (tasks_found == 0) {
                        first_task = task;
                    } else if (new_tail -% head >= Executor.BoundedBuffer.SIZE) {
                        break;
                    } else {
                        self.executor_worker.runq_buffer.write(new_tail, &task.executor_task);
                        new_tail +%= 1;
                    }
                }

                if (new_tail != tail)
                    @atomicStore(usize, self.executor_worker.runq_pos.tailPtr(), new_tail, .Release);
                return first_task;
            }
        };

        pub const Task = extern struct {
            /// A task priority serves as a execution ordering hint to the scheduler.
            pub const Priority = enum(u2) {
                /// The scheduler will make an effort to run Low priority tasks after all others.
                /// This may result in prolonged (not indefinite) starvation.
                Low = 0,
                /// The scheduler will make an effort to run Normal priority tasks at least before Low priority tasks.
                /// Tasks marked as Normal priority are conceptually scheduled in a FIFO order.
                Normal = 1,
                /// The scheduler will make an effort to run a High priority task before all other tasks,
                /// including other currently scheduled High priority tasks.
                /// Tasks marked as High priority are conceptually scheduled ina LIFO order.
                High = 2,
            };

            /// A task affinity restricts which work groups in the scheduler it is allowed to execute in.
            pub const Affinity = union(enum) {
                /// Tasks with a Worker affinity can only be executed on the provided Worker.
                Worker: *Worker,
                /// Tasks with a Node affinity can only be executed on the most previous Node.
                Node: *Node,
                /// Tasks with a Scheduler affinity are free to be scheduled on any Node.
                Scheduler: void,
            };

            pub const RunFn = fn(*Task, *Worker) callconv(.C) void;
            
            executor_task: Executor.Task,
            state: usize,
            run_fn_ptr: *const RunFn,

            /// Create a task struct using the provided scheduler hints and pointer to the ExecuteFn callback.
            pub fn init(
                affinity: Affinity,
                priority: Priority,
                run_fn_ptr: *const RunFn,
            ) Task {
                return Task{
                    .next = null,
                    .state = @enumToInt(priority) | (switch (affinity) {
                        .Worker => |worker| @ptrToInt(worker) | (1 << 2),
                        .Node => |node| @ptrToInt(node),
                        .Scheduler => 0x0,
                    }),
                    .run_fn_ptr = run_fn_ptr,
                };
            }

            /// Get the Priority of the Task.
            pub fn priority(self: Task) Priority {
                return @intToEnum(Priority, @truncate(u2, self.state));
            }

            /// Get the Affinity of the Task.
            pub fn affinity(self: Task) Affinity {
                const ptr = self.state >> 3;
                if (self.state & (1 << 2) != 0)
                    return Affinity{ .Worker = @intToPtr(*Worker, ptr) };
                if (@intToPtr(?*Node, ptr)) |node|
                    return Affinity{ .Node = node };
                return Affinity{ .Scheduler = {} };
            }

            pub const Queue = extern struct {
                executor_queue: Executor.Task.Queue,
                len: usize,

                pub fn init() Queue {
                    return Queue{
                        .executor_queue = Executor.Task.Queue.init(),
                        .len = 0,
                    };
                }

                pub fn from(self: *Task) void {
                    var self = Queue.init();
                    self.push(task);
                    return self;
                }

                pub fn push(noalias self: *Queue, noalias task: *Task) void {
                    const executor_task = &task.executor_task;
                    switch (task.priority()) {
                        .Low, .Normal => self.executor_queue.push(.Back, executor_task),
                        .High => self.executor_queue.push(.Front, executor_task),
                    }
                }

                pub fn pop(self: *Queue) ?*Task {
                    const executor_task = self.executor_queue.pop() orelse return null;
                    return @fieldParentPtr(Task, "executor_task", executor_task);
                }
            };
        };
    };
}