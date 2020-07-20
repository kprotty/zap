const std = @import("std");
const parallel = @import("../core/executor/parallel.zig");

pub fn ThreadPool(comptime Platform: type) type {
    return struct {
        const Executor = parallel.ParallelExecutor(Scheduler);

        pub const Scheduler = extern struct {
            pub const CACHE_LINE = 
                if (std.builtin.arch == .x86_64) 64 * 2
                else 64;

            pub const WORKER_SHARED_BUFFER_SIZE = 256;
            pub const WORKER_POLL_GLOBAL_FREQUENCY = 61;
            pub const WORKER_POLL_SHARED_BACK_FREQUENCY = 31;
            pub const WORKER_POLL_SHARED_FRONT_FREQUENCY = 13;
            pub const WORKER_POLL_LOCAL_FREQUENCY = 7;

            pub const AutoResetEvent = Platform.AutoResetEvent;
            
            platform: *Platform,

            pub fn run(
                platform: *Platform,
                nodes: []*Node,
                task: *Task,
            ) void 

            pub fn runWorker(
                noalias self: *Scheduler,
                noalias executor_worker: *Executor.Worker,
                is_main_thread: bool,
            ) bool {
                // TODO: system.Thread
            }

            pub fn pollWorker(
                noalias self: *Scheduler,
                noalias executor_worker: *Executor.Worker,
                can_block: bool,
            ) ?*Executor.Task {
                const worker = @fieldParentPtr(Worker, "executor_worker", executor_worker);
                const task = self.platform.pollWorker(worker, can_block) orelse return null;
                return &task.executor_task;
            }

            pub fn nodes(self: Scheduler) []*Node {
                const executor_nodes = @fieldParentPtr(Executor.Scheduler, "platform", self).nodes();
                return @ptrCast([*]*Node, executor_nodes.ptr)[0..executor_nodes.len];
            }

            pub const NodeIter = struct {
                node: *Node,
                index: usize,
                executor_nodes: []*Node,

                pub fn init(
                    noalias self: *NodeIter,
                    noalias executor_node: *Executor.Node,
                    executor_nodes: []*Executor.Node,
                    noalias scheduler: *Scheduler,
                ) void {
                    self.* = NodeIter{
                        .node = @fieldParentPtr(Node, "executor_node", executor_node),
                        .index = 0,
                        .executor_nodes = executor_nodes,
                    };
                }

                pub fn deinit(self: *NodeIter) void {
                    self.* = undefined;
                }

                pub fn next(self: *NodeIter) ?*Executor.Node {
                    if (self.index >= self.node.access_order.len)
                        return null;
                    defer self.index +%= 1;
                    return self.executor_nodes[self.node.access_order[self.index]];
                }
            };

            pub const WorkerIter = struct {
                worker: *Worker,
                access_prefer: usize,
                executor_workers: []*Executor.Worker,

                pub fn init(
                    noalias self: *WorkerIter,
                    noalias executor_worker: *Executor.Worker,
                    executor_workers: []*Executor.Worker,
                    noalias scheduler: *Scheduler,
                ) void {
                    const worker = @fieldParentPtr(Worker, "executor_worker", executor_worker);
                    self.* = WorkerIter{
                        .worker = worker,
                        .access_prefer = worker.access_prefer,
                        .executor_workers = executor_workers,
                    };
                }

                pub fn deinit(self: *WorkerIter) void {
                    self.* = undefined;
                }

                pub fn next(self: *WorkerIter) ?*Executor.Worker {
                    // TODO: first self, then access_prefer if on same node. Else/then random iter
                }
            };
        };

        pub const Node = struct {
            pub const Index = u8;
            pub const MAX = std.math.maxInt(Index) + 1;

            pub const Affinity = struct {
                group: Group,
                mask: usize,

                pub const Group = @Type(std.builtin.TypeInfo{
                    .Int = std.builtin.TypeInfo.Int{
                        .bits = @ctz(usize, MAX / @typeInfo(usize).Int.bits),
                        .is_signed = false,
                    },
                });
            };

            executor_node: Executor.Node,
            numa_node: ?u32,
            affinity: ?Affinity,
            access_order: []Index,

            pub fn prepare(
                self: *Node,
                numa_node: ?u32,
                affinity: ?Affinity,
                access_order: []Index,
                workers: []*Worker,
            ) !void {
                self.* = Node{
                    .executor_node = undefined,
                    .numa_node = numa_node,
                    .affinity = affinity,
                    .access_order = access_order,
                };
                self.executor_node.prepare(workers);
            }

            pub fn scheduler(self: Node) *Scheduler {
                return self.executor_node.scheduler().platform;
            }
        };

        pub const Worker = struct {
            executor_worker: Executor.Worker,
            affinity_mask: ?usize,
            access_prefer: usize,

            pub fn prepare(
                self: *Worker,
                affinity_mask: ?usize,
                access_prefer: usize,
            ) void {
                self.* = Worker{
                    .executor_worker = undefined,
                    .affinity_mask = affinity_mask,
                    .access_prefer = .access_prefer,
                };
            }

            pub fn node(self: Worker) *Node {
                return @fieldParentPtr(Node, "executor_node", self.executor_worker.node());
            }
        };

        pub const Task = struct {
            pub const Priority = enum {
                Low,
                Normal,
                High,

                fn encode(self: Priority) Executor.Priority {
                    return switch (self) {
                        .Low => Executor.Priority.Low,
                        .Normal => Executor.Priority.Normal,
                        .High => Executor.Priority.High,
                    };
                }

                fn decode(executor_priority: Executor.Priority) Priority {
                    return switch (executor_priority) {
                        Executor.Priority.Low => .Low,
                        Executor.Priority.Normal => .Normal,
                        Executor.Priority.High => .High,
                    };
                }
            };

            pub const Affinity = union(enum) {
                Worker: *Worker,
                Node: *Node,
                Scheduler: void,

                fn encode(self: Affinity) Executor.Affinity {
                    return switch (self) {
                        .Worker => |worker| Executor.Affinity{ .Worker = &worker.executor_worker },
                        .Node => |node| Executor.Affinity{ .Node = &node.executor_node },
                        .Scheduler => Executor.Affinity{ .Scheduler = {} },
                    };
                }

                fn decode(executor_affinity: Executor.Affinity) Affinity {
                    return switch (executor_affinity) {
                        .Worker => |executor_worker| Affinity{ .Worker = @fieldParentPtr(Worker, "executor_worker", executor_worker) },
                        .Node => |executor_node| Affinity{ .Node = @fieldParentPtr(Node, "executor_node", executor_node) },
                        .Scheduler => Affinity{ .Scheduler = {} },
                    };
                }
            };

            frame: anyframe,
            executor_task: Executor.Task,

            pub fn getResumeContext() ?*ResumeContext {
                return ResumeContext.current;
            }

            pub const ResumeContext = struct {
                threadlocal var current: ?*ResumeContext = null;

                worker: *Worker,
                priority: Priority,
                affinity: Affinity,
                next_task: ?*Task,

                fn @"resume"(
                    executor_task: *Executor.Task,
                    executor_worker: *Executor.Worker,
                ) callconv(.C) void {
                    var context = ResumeContext{
                        .worker = @fieldParentPtr(Worker, "executor_worker", executor_worker),
                        .affinity = Affinity.decode(executor_task.affinity),
                        .priority = Priority.decode(executor_task.priority),
                        .next_task = @fieldParentPtr(Task, "executor_task", executor_task),
                    };

                    const old_context = ResumeContext.current;
                    ResumeContext.current = &context;
                    defer ResumeContext.current = old_context;

                    var iteration: usize = 0;
                    const platform = context.worker.node().scheduler().platform;
                    while (true) : (iteration +%= 1) {
                        const task = context.next_task orelse break;
                        if (!platform.keepResuming(context.worker, task, iteration))
                            break;
                        context.next_task = null;
                        resume task.frame;
                    }

                    if (context.next_task) |task|
                        context.worker.schedule(Task.Queue.from(task));
                }

                pub fn init(self: ResumeContext, frame: anyframe) Task {
                    return Task{
                        .frame = frame,
                        .executor_task = Executor.Task.init(
                            context.priority.encode(),
                            context.affinity.encode(),
                            &@"resume",
                        ),
                    };
                }

                pub fn setPriority(self: *ResumeContext, priority: Priority) void {
                    self.priority = priority;
                }

                pub fn setAffinity(self: *ResumeContext, affinity: Affinity) void {
                    self.priority = priority;
                }

                pub fn schedule(self: ResumeContext, batch: Task.Queue) void {
                    return self.worker.schedule(batch);
                }

                pub fn yield(self: ResumeContext) void {
                    var task = self.init(@frame());
                    suspend {
                        self.schedule(Task.Queue.from(&task));
                    }
                }

                pub fn yieldInto(self: ResumeContext, task: *Task) void {
                    var task = self.init(@frame());
                    suspend {
                        self.next_task = &task;
                    }
                }
            };

            pub const AutoResetEvent = struct {
                const EMPTY = std.math.minInt(usize);
                const NOTIFIED = std.math.maxInt(usize);

                state: usize = EMPTY,

                pub fn init(self: *AutoResetEvent) void {
                    self.* = AutoResetEvent{};
                }

                pub fn deinit(self: *AutoResetEvent) void {
                    defer self.* = undefined;
                    if (std.debug.runtime_safety) {
                        const state = @atomicLoad(usize, &self.state, .Monotonic);
                        std.debug.assert(state == EMPTY or state == NOTIFIED);
                    }
                }

                pub fn set(self: *AutoResetEvent) void {
                    var state = @atomicLoad(usize, &self.state, .Acquire);

                    if (state == EMPTY) {
                        state = @cmpxchgStrong(
                            usize,
                            &self.state,
                            EMPTY,
                            NOTIFIED,
                            .Acquire,
                            .Acquire,
                        ) orelse return;
                    }

                    if (state == NOTIFIED)
                        return;

                    std.debug.assert(state != EMPTY);
                    @atomicStore(usize, &self.state, EMPTY, .Release);
                    
                    const task = @intToPtr(*Task, state);
                    Task.getResumeContext().?.yieldInto(task);
                }

                pub fn wait(self: *AutoResetEvent) void {
                    var state = @atomicLoad(usize, &self.state, .Acquire);

                    if (state == EMPTY) {
                        var task = Task.init(@frame());
                        suspend {
                            if (@cmpxchgStrong(
                                usize,
                                &self.state,
                                EMPTY,
                                @ptrToInt(&task),
                                .Release,
                                .Acquire,
                            )) |new_state| {
                                state = new_state;
                                resume @frame();
                            }
                        }
                    }

                    std.debug.assert(state == NOTIFIED);
                    @atomicStore(usize, &self.state, EMPTY, .Monotonic);
                }
            };
        };
    };
}