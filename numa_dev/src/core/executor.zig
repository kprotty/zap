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

pub const Scheduler = extern struct {
    nodes: Node.Cluster,
    nodes_active: usize,

    pub fn init(
        noalias self: *Scheduler,
        cluster: Node.Cluster,
    ) void {
        self.* = Scheduler{
            .nodes = cluster,
            .nodes_active = 0,
        };
    }

    pub fn deinit(noalias self: *Scheduler) void {
        self.* = undefined;
    }

    pub const StartError = error {
        EmptyNodes,
        EmptyWorkers,
        InvalidStartingNode,
    };

    pub fn start(
        noalias self: *Scheduler,
        starting_node_index: usize,
        noalias starting_task: *Task,
    ) StartError!*Worker {
        if (self.nodes.isEmpty()) {
            return StartError.EmptyNodes;
        }

        var starting_node_ptr: ?*Node = null;
        var node_index: usize = 0;
        var nodes = self.nodes.iter();
        while (nodes.next()) |node| {
            if (node_index == starting_node_index)
                starting_node_ptr = node;
            node.start(self); 
            node_index += 1;
        }

        const starting_node = starting_node_ptr orelse {
            return StartError.InvalidStartingNode;
        };

        const schedule = starting_node.tryResumeThread(.{}) orelse {
            return StartError.EmptyWorkers;
        };

        return switch (schedule.action) {
            .resumed => std.debug.panic("Scheduler.start() with already spawned thread", .{}),
            .spawned => |worker| blk: {
                schedule.node.pushBack(Task.Batch.from(starting_task));
                break :blk worker;
            },
        };
    }

    pub fn shutdown(noalias self: *Scheduler) ThreadResumeIter {
        var idle_threads: ?*Thread = null;

        var nodes = self.nodes.iter();
        while (nodes.next()) |node| {
            idle_threads = node.shutdown(idle_threads);
        }

        return ThreadResumeIter{
            .idle_threads = idle_threads,
        };
    }

    pub const ThreadResumeIter = extern struct {
        idle_threads: ?*Thread,

        pub fn next(noalias self: *ThreadResumeIter) ?*Thread {
            const thread = self.idle_threads orelse return null;
            self.idle_threads = @intToPtr(?*Thread, thread.ptr);
            return thread;
        }
    };

    pub fn finish(noalias self: *Scheduler) ThreadHandleIter {
        const nodes_active = @atomicLoad(usize, &self.nodes_active, .Monotonic);
        if (nodes_active != 0)
            std.debug.panic("Scheduler.finish() with {} node active", .{nodes_active});

        var nodes = self.nodes.iter();
        while (nodes.next()) |node| {
            node.finish();
        }

        return ThreadHandleIter{
            .node_iter = self.nodes.iter(),
            .worker_index = undefined,
            .node = null,
        };
    }

    pub const ThreadHandleIter = extern struct {
        node_iter: Node.Iter,
        worker_index: usize,
        node: ?*Node,

        pub fn next(noalias self: *ThreadHandleIter) Thread.Handle {
            while (true) {
                const node = self.node orelse blk: {
                    const new_node = self.node_iter.next() orelse return null;
                    self.worker_index = 0;
                    self.node = new_node;
                    break :blk new_node;
                };

                while (self.worker_index < node.workers_len) {
                    const ptr = @atomicLoad(usize, &node.workers_ptr[self.worker_index].ptr, .Acquire);
                    self.worker_index += 1;
                    switch (Worker.Ref.decode(ptr)) {
                        .handle => |handle| {
                            return handle orelse continue;
                        },
                        else => |worker_ref| {
                            std.debug.panic("Invalid worker ref on thread handle iter {}", .{worker_ref});
                        },
                    }
                }

                self.node = null;
            }
        }
    };
};

pub const Node = extern struct {
    pub const Cluster = extern struct {
        head: ?*Node = null,
        tail: *Node = undefined,

        pub fn from(node: *Node) Cluster {
            node.next = node;
            return Cluster{
                .head = node,
                .tail = node,
            };
        }

        pub fn isEmpty(self: Cluster) bool {
            return self.head == null;
        }

        pub fn pushFront(noalias self: *Cluster, noalias node: *Node) void {
            return self.pushFrontMany(Cluster.from(node));
        }

        pub fn pushBack(noalias self: *Cluster, noalias node: *Node) void {
            return self.pushBackMany(Cluster.from(node));
        }

        pub fn pushFrontMany(self: *Cluster, cluster: Cluster) void {
            const cluster_head = cluster.head orelse return;
            if (self.head) |head| {
                cluster.tail.next = head;
                self.head = cluster_head;
                self.tail.next = cluster_head;
            } else {
                self.* = cluster;
            }
        }

        pub fn pushBackMany(self: *Cluster, cluster: Cluster) void {
            const cluster_head = cluster.head orelse return;
            if (self.head) |head| {
                self.tail.next = cluster_head;
                self.tail = cluster.tail;
                cluster.tail.next = head;
            } else {
                self.* = cluster;
            }
        }

        pub fn iter(self: Cluster) Iter {
            return Iter.from(self.head);
        }
    };

    pub const Iter = extern struct {
        start: ?*Node,
        current: ?*Node,

        fn from(node: ?*Node) Iter {
            return Iter{
                .start = node,
                .current = node,
            };
        }

        pub fn next(noalias self: *Iter) ?*Node {
            const node = self.current orelse return null;
            self.current = node.next;
            if (self.current == self.start)
                self.current = null;
            return node;
        }
    };

    next: ?*Node,
    scheduler: *Scheduler,
    workers_ptr: [*]Worker,
    workers_len: u16,
    runq_stub: ?*Task,
    runq_tail: usize,
    runq_head: *Task,
    idle_queue: usize,
    threads_active: usize,

    pub const MAX_WORKERS = std.math.maxInt(u16) - 1;

    pub fn init(noalias self: *Node, workers: []Worker) void {
        self.workers_ptr = workers.ptr;
        self.workers_len = @truncate(u16, std.math.min(MAX_WORKERS, workers.len));
    }

    pub fn deinit(noalias self: *Node) void {
        self.* = undefined;
    }

    fn start(noalias self: *Node, noalias scheduler: *Scheduler) void {
        self.scheduler = scheduler;
        self.runq_stub = null;
        self.runq_head = @fieldParentPtr(Task, "next", &self.runq_stub);
        self.runq_tail = @ptrToInt(self.runq_head);
        self.threads_active = 0;

        self.idle_queue = 0;
        for (self.getWorkers()) |*worker, index| {
            const next_index = @intCast(u16, self.idle_queue >> 16);
            const next_worker = self.fromWorkerIndex(next_index);
            worker.ptr = (Worker.Ref{ .worker = next_worker }).encode();
            self.idle_queue = @as(usize, self.toWorkerIndex(worker)) << 16;
        }
    }

    fn finish(noalias self: *Node) void {
        const runq_stub = @fieldParentPtr(Task, "next", &self.runq_stub);
        const runq_head = @atomicLoad(*Task, &self.runq_head, .Monotonic);
        const runq_tail = @atomicLoad(usize, &self.runq_tail, .Monotonic);
        const idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
        const threads_active = @atomicLoad(usize, &self.threads_active, .Monotonic);
        
        if (idle_queue != IDLE_SHUTDOWN)
            std.debug.panic("Node.finish() when not shutdown", .{});
        if (threads_active != 0)
            std.debug.panic("Node.finish() with {} active threads", .{threads_active});
        if (runq_tail & 1 != 0)
            std.debug.panic("Node.finish() when runq is being polled", .{});
        if ((runq_head != runq_stub) or (@intToPtr(*Task, runq_tail) != runq_stub))
            std.debug.panic("Node.finish() when runq not empty", .{});
    }

    pub fn iter(noalias self: *Node) Iter {
        return Iter.from(self);
    }

    fn pushBack(
        noalias self: *Node,
        batch: Task.Batch,
    ) void {
        const head = batch.head orelse return;
        const tail = batch.tail;
        const prev = @atomicRmw(*Task, &self.runq_head, .Xchg, tail, .AcqRel);
        @atomicStore(?*Task, &prev.next, head, .Release);
    }

    fn popFront(
        noalias self: *Node,
        noalias thread: *Thread,
        noalias runq_tail: **Task,
    ) ?*Task {
        var tail = runq_tail.*;
        var next = @atomicLoad(?*Task, &tail.next, .Acquire);

        const stub = @fieldParentPtr(Task, "next", &self.runq_stub);
        if (tail == stub) {
            tail = next orelse return null;
            runq_tail.* = tail;
            next = @atomicLoad(?*Task, &tail.next, .Acquire);
        }

        if (next) |next_task| {
            runq_tail.* = next_task;
            return tail;
        }

        var head = @atomicLoad(*Task, &self.runq_head, .Monotonic);
        if (head != tail) {
            return null;
        }

        self.pushBack(Task.Batch.from(stub));
        runq_tail.* = @atomicLoad(?*Task, &tail.next, .Acquire) orelse return null;
        return tail;
    }

    pub fn getScheduler(noalias self: *Node) *Scheduler {
        return self.scheduler;
    }

    pub fn getWorkers(noalias self: *Node) []Worker {
        return self.workers_ptr[0..self.workers_len];
    }

    fn fromWorkerIndex(noalias self: *Node, worker_index: u16) ?*Worker {
        if (worker_index == 0)  
            return null;
        return &self.workers_ptr[worker_index - 1];
    }

    fn toWorkerIndex(noalias self: *Node, noalias worker: ?*Worker) u16 {
        const worker_ptr = worker orelse return 0;
        const offset = @ptrToInt(worker_ptr) - @ptrToInt(self.workers_ptr);
        const index = offset / @sizeOf(Worker);
        return @intCast(u16, index + 1);
    }

    const IDLE_SHUTDOWN = ~@as(usize, 0);
    const IDLE_NOTIFIED = 1 << 0;
    const IDLE_WAKING = 1 << 1;

    const ResumeContext = struct {
        is_waking: bool = false,
        is_remote: bool = false,
    };

    fn tryResumeThread(
        noalias self: *Node,
        context: ResumeContext,
    ) ?Thread.Schedule {
        const is_waking = context.is_waking;
        var idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);

        while (true) {
            var flags = @truncate(u8, idle_queue);
            const aba_tag = @truncate(u8, idle_queue >> 8);
            var worker_index = @truncate(u16, idle_queue >> 16);

            if (idle_queue == IDLE_SHUTDOWN)
                std.debug.panic("Node.tryResumeThread() when shutdowm", .{});

            var schedule_action: ?Thread.Schedule.Action = null;
            if (!is_waking and ((flags == IDLE_NOTIFIED) or (flags & IDLE_WAKING != 0))) {
                break;
            } else if (self.fromWorkerIndex(worker_index)) |worker| {
                flags = IDLE_WAKING;
                switch (Worker.Ref.decode(@atomicLoad(usize, &worker.ptr, .Acquire))) {
                    .handle => {
                        std.debug.panic("Node.tryResumeThread() when worker is shutting down", .{});
                    },
                    .node => {
                        idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
                        continue;
                    },
                    .worker => |next_worker| {
                        worker_index = self.toWorkerIndex(next_worker);
                        schedule_action = Thread.Schedule.Action{ .spawned = worker };
                    },
                    .thread => |thread| {
                        const thread_ptr = @atomicLoad(usize, &thread.ptr, .Unordered);
                        if (thread_ptr < (MAX_WORKERS + 1)) {
                            worker_index = @intCast(u16, thread_ptr);
                            schedule_action = Thread.Schedule.Action{ .resumed = thread };
                        } else {
                            idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
                            continue;
                        }
                    },
                }
            } else {
                flags = IDLE_NOTIFIED;
            }

            const new_idle_queue =
                @as(usize, flags) |
                (@as(usize, aba_tag) << 8) |
                (@as(usize, worker_index) << 16);
            
            if (@cmpxchgWeak(
                usize,
                &self.idle_queue,
                idle_queue,
                new_idle_queue,
                .Acquire,
                .Monotonic,
            )) |updated_idle_queue| {
                idle_queue = updated_idle_queue;
                continue;
            }

            const action = schedule_action orelse return null;
            switch (action) {
                .resumed => |thread| {
                    @atomicStore(usize, &thread.ptr, 1, .Unordered);
                },
                .spawned => |worker| blk: {
                    const worker_ref = Worker.Ref{ .node = self };
                    @atomicStore(usize, &worker.ptr, worker_ref.encode(), .Release);
                },
            }

            const threads_active = @atomicRmw(usize, &self.threads_active, .Add, 1, .Monotonic);
            if (threads_active == 0) {
                _ = @atomicRmw(usize, &self.scheduler.nodes_active, .Add, 1, .Monotonic);
            }

            return Thread.Schedule{
                .node = self,
                .action = action,
            };
        }

        if (!context.is_remote) {
            var nodes = self.iter();
            _ = nodes.next();
            while (nodes.next()) |remote_node| {
                if (remote_node.tryResumeThread(.{
                    .is_waking = is_waking,
                    .is_remote = true,
                })) |schedule| {
                    return schedule;
                }
            }
        }

        return null;
    }

    fn undoResumeThread(
        noalias self: *Node,
        action: Thread.Schedule.Action,
    ) void {
        var idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
        while (true) {
            var flags = @truncate(u8, idle_queue);
            const aba_tag = @truncate(u8, idle_queue >> 8);
            var worker_index = @truncate(u16, idle_queue >> 16);

            if (idle_queue == IDLE_SHUTDOWN)
                std.debug.panic("Node.undoResumeThread() when shutdown", .{});
            if (flags & IDLE_WAKING == 0)
                std.debug.panic("Node.undoResumeThread() when not waking", .{});

            flags &= ~@as(u8, IDLE_NOTIFIED);
            switch (action) {
                .resumed => |thread| {
                    @atomicStore(usize, &thread.ptr, worker_index, .Unordered);
                    worker_index = self.toWorkerIndex(thread.worker);
                },
                .spawned => |worker| {
                    const next_worker = self.fromWorkerIndex(worker_index);
                    const worker_ref = Worker.Ref{ .worker = next_worker };
                    @atomicStore(usize, &worker.ptr, worker_ref.encode(), .Monotonic);
                    worker_index = self.toWorkerIndex(worker);
                },
                else => unreachable,
            }

            const new_idle_queue =
                @as(usize, flags) |
                (@as(usize, aba_tag +% 1) << 8) |
                (@as(usize, worker_index) << 16);

            idle_queue = @cmpxchgWeak(
                usize,
                &self.idle_queue,
                idle_queue,
                new_idle_queue,
                .AcqRel,
                .Monotonic,
            ) orelse break;
        }

        const threads_active = @atomicRmw(usize, &self.threads_active, .Sub, 1, .Monotonic);
        if (threads_active == 1) {
            _ = @atomicRmw(usize, &self.scheduler.nodes_active, .Sub, 1, .Monotonic);
        }
    }

    fn trySuspendThread(
        noalias self: *Node,
        noalias thread: *Thread,
        noalias worker: *Worker,
        is_waking: bool,
    ) ?bool {
        const old_ptr = thread.ptr;
        var idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);

        while (true) {
            var flags = @truncate(u8, idle_queue);
            var aba_tag = @truncate(u8, idle_queue >> 8);
            var worker_index = @truncate(u16, idle_queue >> 16);

            if (idle_queue == IDLE_SHUTDOWN)
                std.debug.panic("Node.trySuspendThread() when shutdown", .{});
            if (is_waking and (flags & IDLE_WAKING == 0))
                std.debug.panic("Node.trySuspendThread(is_waking) when not waking", .{});

            var is_notified = false;
            if (flags == IDLE_NOTIFIED) {
                flags &= ~@as(u8, IDLE_NOTIFIED);
                is_notified = true;
            } else {
                if (is_waking)
                    flags &= ~@as(u8, IDLE_WAKING);
                @atomicStore(usize, &thread.ptr, worker_index, .Unordered);
                worker_index = self.toWorkerIndex(worker);
            }

            const new_idle_queue =
                @as(usize, flags) |
                (@as(usize, aba_tag +% 1) << 8) |
                (@as(usize, worker_index) << 16);

            if (@cmpxchgWeak(
                usize,
                &self.idle_queue,
                idle_queue,
                new_idle_queue,
                .AcqRel,
                .Monotonic,
            )) |updated_idle_queue| {
                idle_queue = updated_idle_queue;
                continue;
            }

            if (is_notified) {
                @atomicStore(usize, &thread.ptr, old_ptr, .Unordered);
                return null;
            }

            const threads_active = @atomicRmw(usize, &self.threads_active, .Sub, 1, .Monotonic);
            if (threads_active == 1) {
                const nodes_active = @atomicRmw(usize, &self.scheduler.nodes_active, .Sub, 1, .Monotonic);
                if (nodes_active == 1) {
                    return true;
                }
            }

            return false;
        }
    }

    fn shutdown(
        noalias self: *Node,
        noalias idle_threads_init: ?*Thread,
    ) ?*Thread {
        var idle_workers: u16 = 0;
        var idle_threads = idle_threads_init;
        var idle_queue = @atomicRmw(usize, &self.idle_queue, .Xchg, IDLE_SHUTDOWN, .Acquire);

        if (idle_queue == IDLE_SHUTDOWN)
            std.debug.panic("Node.shutdown() when already shutdown", .{});
        if (idle_queue & IDLE_WAKING != 0)
            std.debug.panic("Node.shutdown() when a thread is waking", .{});
        if (idle_queue & IDLE_NOTIFIED != 0)
            std.debug.panic("Node.shutdown() when idle queue notified", .{});

        const workers = self.workers_ptr;
        var worker_index = @truncate(u16, idle_queue >> 16);
        while (worker_index != 0) {
            idle_workers += 1;
            const worker = &workers[worker_index - 1];
            switch (Worker.Ref.decode(@atomicLoad(usize, &worker.ptr, .Acquire))) {
                .node => {
                    std.debug.panic("Node.shutdown() when worker is spawning", .{});
                },
                .handle => {
                    std.debug.panic("Node.shutdown() when worker is already shutdown", .{});
                },
                .worker => |next_worker| {
                    worker_index = self.toWorkerIndex(next_worker);
                    const worker_ref = Worker.Ref{ .handle = null };
                    @atomicStore(usize, &worker.ptr, worker_ref.encode(), .Monotonic);
                },
                .thread => |thread| {
                    thread.worker = null;
                    worker_index = @intCast(u16, thread.ptr);
                    const worker_ref = Worker.Ref{ .handle = thread.handle };
                    @atomicStore(usize, &worker.ptr, worker_ref.encode(), .Monotonic);

                    thread.ptr = @ptrToInt(idle_threads);
                    idle_threads = thread;
                },
            }
        }

        if (idle_workers != self.workers_len) {
            std.debug.panic("Node.shutdown() when only {}/{} workers were idle", .{idle_workers, self.workers_len});
        }

        return idle_threads;
    }
};

pub const Worker = extern struct {
    ptr: usize,

    const Ref = union(enum) {
        worker: ?*Worker,
        node: *Node,
        thread: *Thread,
        handle: Thread.Handle,

        fn encode(self: Ref) usize {
            return switch (self) {
                .worker => |ptr| @ptrToInt(ptr) | 0,
                .node => |ptr| @ptrToInt(ptr) | 1,
                .thread => |ptr| @ptrToInt(ptr) | 2,
                .handle => |ptr| @ptrToInt(ptr) | 3,
            };
        }

        fn decode(value: usize) Ref {
            const ptr = value & ~@as(usize, 0b11);
            return switch (value & 0b11) {
                0 => Ref{ .worker = @intToPtr(?*Worker, ptr) },
                1 => Ref{ .node = @intToPtr(*Node, ptr) },
                2 => Ref{ .thread = @intToPtr(*Thread, ptr) },
                3 => Ref{ .handle = @intToPtr(Thread.Handle, ptr) },
                else => unreachable,
            };
        }
    };
};

pub const Thread = extern struct {
    pub const Handle = ?*u32;

    prng: u16,
    ptr: usize,
    worker: ?*Worker,
    node: *Node,
    handle: Handle,
    runq_next: ?*Task,
    runq_head: usize,
    runq_tail: usize,
    runq_buffer: [256]*Task,

    pub fn init(
        noalias self: *Thread,
        noalias worker: *Worker,
        handle: Handle,
    ) void {
        const worker_ptr = @atomicLoad(usize, &worker.ptr, .Acquire);
        const node = switch (Worker.Ref.decode(worker_ptr)) {
            .node => |node| node,
            else => |worker_ref| std.debug.panic("Invalid worker ref {} on Thread.init()", .{worker_ref}),
        };

        self.* = Thread{
            .prng = @truncate(u16, (@ptrToInt(node) ^ @ptrToInt(self)) >> 16),
            .ptr = 1,
            .worker = worker,
            .node = node,
            .handle = handle,
            .runq_next = null,
            .runq_head = 0,
            .runq_tail = 0,
            .runq_buffer = undefined,
        };

        const worker_ref = Worker.Ref{ .thread = self };
        @atomicStore(usize, &worker.ptr, worker_ref.encode(), .Release);
    }

    pub fn deinit(noalias self: *Thread) void {
        const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        const tail = @atomicLoad(usize, &self.runq_tail, .Monotonic);
        const next = @atomicLoad(?*Task, &self.runq_next, .Monotonic);

        if (self.worker != null)
            std.debug.panic("Thread.deinit() before shutdown", .{});
        if (next != null)
            std.debug.panic("Thread.deinit() with pending runq next {*}", .{next});
        if (tail != head)
            std.debug.panic("Thread.deinit() with {} pending runq tasks", .{tail -% head});
    }

    pub fn getNode(noalias self: *Thread) *Node {
        return self.node;
    }

    pub const Schedule = struct {
        node: *Node,
        action: Action,

        pub const Action = union(enum) {
            resumed: *Thread,
            spawned: *Worker,
        };
    };

    pub const Syscall = union(enum) {
        run: *Task,
        shutdown: void,
        suspended: bool,
        scheduled: Schedule,
    };

    pub fn poll(noalias self: *Thread) Syscall {
        const worker = self.worker orelse return Syscall{ .shutdown = {} };
        const is_waking = self.ptr & 1 != 0;
        const node = self.node;

        while (true) {
            var polled_node = false;
            const next_task = blk: {
                if (@intToPtr(?*Task, self.ptr & ~@as(usize, 1))) |task| {
                    break :blk task;
                }

                if (self.pollSelf()) |task| {
                    break :blk task;
                }

                var nodes = node.iter();
                while (nodes.next()) |target_node| {
                    if (self.pollNode(target_node)) |task| {
                        polled_node = true;
                        break :blk task;
                    }

                    var prng = self.prng;
                    prng ^= prng << 7;
                    prng ^= prng >> 9;
                    prng ^= prng << 8;
                    self.prng = prng;

                    const workers = target_node.workers_ptr;
                    const num_workers = target_node.workers_len;
                    var worker_index = prng % num_workers;

                    var worker_iter = num_workers;
                    while (worker_iter != 0) : (worker_iter -= 1) {
                        const current_index = worker_index;
                        const target_worker = &workers[current_index];
                        worker_index = if (worker_index == num_workers - 1) 0 else (worker_index + 1);
                        
                        const target_worker_ptr = @atomicLoad(usize, &target_worker.ptr, .Acquire);
                        switch (Worker.Ref.decode(target_worker_ptr)) {
                            .node => {},
                            .worker => {},
                            .handle => {
                                std.debug.panic("Worker {} with thread handle set when stealing", .{current_index});
                            },
                            .thread => |target_thread| {
                                if (target_thread == self)
                                    continue;
                                if (self.pollThread(target_thread)) |task|
                                    break :blk task;
                            }
                        }
                    }
                }

                break :blk null;
            };

            if (next_task) |task| {
                if (is_waking or polled_node) {
                    if (node.tryResumeThread(.{ .is_waking = is_waking })) |schedule_action| {
                        self.ptr = @ptrToInt(task);
                        return Syscall{ .scheduled = schedule_action };
                    }
                }
                self.ptr = 0;
                return Syscall{ .run = task };
            }

            if (node.trySuspendThread(self, worker, is_waking)) |last_thread| {
                return Syscall{ .suspended = last_thread };
            }
        }
    }

    fn pollSelf(
        noalias self: *Thread,
    ) ?*Task {
        var runq_next = @atomicLoad(?*Task, &self.runq_next, .Monotonic);
        while (runq_next) |next| {
            runq_next = @cmpxchgWeak(
                ?*Task,
                &self.runq_next,
                next,
                null,
                .Monotonic,
                .Monotonic,
            ) orelse return next;
        }

        const tail = self.runq_tail;
        var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        while (true) {
            const size = tail -% head;
            if (size == 0)
                break;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.pollSelf() with invalid runq size {}", .{size}); 

            head = @cmpxchgWeak(
                usize,
                &self.runq_head,
                head,
                head +% 1,
                .Monotonic,
                .Monotonic,
            ) orelse return self.runq_buffer[head % self.runq_buffer.len];
        }

        return null;
    }

    fn pollThread(
        noalias self: *Thread,
        noalias target: *Thread,
    ) ?*Task {
        const tail = self.runq_tail;
        const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        if (tail != head)
            std.debug.panic("Thread.pollThread() with non-empty ({}) runq", .{tail -% head});
        
        var target_head = @atomicLoad(usize, &target.runq_head, .Acquire);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.runq_tail, .Acquire);
            const target_size = target_tail -% target_head;
            if (target_size > target.runq_buffer.len) {
                target_head = @atomicLoad(usize, &target.runq_head, .Acquire);
                continue;
            }

            var steal = target_size - (target_size / 2);
            if (steal == 0) {
                const target_next = @atomicLoad(?*Task, &target.runq_next, .Monotonic) orelse return null;
                _ = @cmpxchgWeak(
                    ?*Task,
                    &target.runq_next,
                    target_next,
                    null,
                    .Acquire,
                    .Monotonic,
                ) orelse return target_next;
                target_head = @atomicLoad(usize, &target.runq_head, .Acquire);
                continue;
            }

            steal -= 1;
            var new_tail = tail;
            var new_target_head = target_head +% 1;
            const first_task = target.runq_buffer[target_head % target.runq_buffer.len];

            while (steal != 0) : (steal -= 1) {
                const task = target.runq_buffer[new_target_head % target.runq_buffer.len];
                self.runq_buffer[new_tail % self.runq_buffer.len] = task;
                new_target_head +%= 1;
                new_tail +%= 1;
            }

            if (@cmpxchgWeak(
                usize,
                &target.runq_head,
                target_head,
                new_target_head,
                .Release,
                .Acquire,
            )) |updated_target_head| {
                target_head = updated_target_head;
                continue;
            }

            if (tail != new_tail)
                @atomicStore(usize, &self.runq_tail, new_tail, .Release);
            return first_task;
        }
    }

    fn pollNode(
        noalias self: *Thread,
        noalias node: *Node,
    ) ?*Task {
        var runq_tail = @atomicLoad(usize, &node.runq_tail, .Monotonic);
        while (true) {
            if (runq_tail & 1 != 0)
                return null;
            runq_tail = @cmpxchgWeak(
                usize,
                &node.runq_tail,
                runq_tail,
                runq_tail | 1,
                .Acquire,
                .Monotonic,
            ) orelse break;
        }

        var node_tail = @intToPtr(*Task, runq_tail);
        var first_task = node.popFront(self, &node_tail);
        var next_task = node.popFront(self, &node_tail);

        const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        const tail = self.runq_tail;
        const size = tail -% head;
        if (size > self.runq_buffer.len)
            std.debug.panic("Thread.pollNode() with invalid runq size of {}", .{size});

        var new_tail = tail;
        while (new_tail -% head < self.runq_buffer.len) {
            const task = node.popFront(self, &node_tail) orelse break;
            if (first_task == null) {
                first_task = task;
            } else {
                self.runq_buffer[new_tail % self.runq_buffer.len] = task;
                new_tail +%= 1;
            }
        }

        @atomicStore(usize, &node.runq_tail, @ptrToInt(node_tail), .Release);

        if (first_task == null) {
            first_task = next_task;
            next_task = null;
        }

        if (next_task) |next|
            @atomicStore(?*Task, &self.runq_next, next, .Release);
        if (new_tail != tail)
            @atomicStore(usize, &self.runq_tail, new_tail, .Release);
        return first_task;
    }

    pub fn schedule(noalias self: *Thread, batch: Task.Batch) ?Schedule {
        var tasks = batch;
        const node = self.node;
        const tail = self.runq_tail;
        var new_tail = tail;

        next_task: while (true) {
            var task = tasks.popBack() orelse break;
            const priority = task.getPriority();

            if (priority == .lifo) {
                var runq_next = @atomicLoad(?*Task, &self.runq_next, .Monotonic);
                while (true) {
                    const next = runq_next orelse blk: {
                        @atomicStore(?*Task, &self.runq_next, task, .Release);
                        break :next_task;
                    };
                    
                    if (@cmpxchgWeak(
                        ?*Task,
                        &self.runq_next,
                        next,
                        task,
                        .Release,
                        .Monotonic,
                    )) |new_runq_next| {
                        runq_next = new_runq_next;
                        continue;
                    }

                    task = next;
                    break;
                }
            }

            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
            while (true) {
                const size = new_tail -% head;
                if (size > self.runq_buffer.len)
                    std.debug.panic("Thread.schedule() with invalid runq size {}", .{size}); 

                if (size < self.runq_buffer.len) {
                    self.runq_buffer[new_tail % self.runq_buffer.len] = task;
                    new_tail +%= 1;
                    continue :next_task;
                }

                var migrate: usize = self.runq_buffer.len / 2;
                if (@cmpxchgWeak(
                    usize,
                    &self.runq_head,
                    head,
                    head +% migrate,
                    .Monotonic,
                    .Monotonic,
                )) |new_head| {
                    head = new_head;
                    continue;
                }

                var overflowed = Task.Batch{};
                while (migrate != 0) : (migrate -= 1) {
                    overflowed.pushBack(self.runq_buffer[head % self.runq_buffer.len]);
                    head +%= 1;
                }

                if (priority == .fifo)
                    tasks.pushFront(task);
                overflowed.pushBackMany(tasks);
                if (priority == .lifo)
                    overflowed.pushFront(task);

                tasks = overflowed;
                break :next_task;
            }
        }

        if (new_tail != tail)
            @atomicStore(usize, &self.runq_tail, new_tail, .Release);
        if (!tasks.isEmpty())
            node.pushBack(tasks);

        return node.tryResumeThread(.{});
    }

    pub fn undoSchedule(
        noalias self: *Thread,
        schedule_action: Schedule,
    ) void {
        const node = schedule_action.node;
        const action = schedule_action.action;
        return node.undoResumeThread(action);
    }
};

pub const Task = extern struct {
    pub const Callback = fn(
        noalias *Task,
        noalias *Thread,
    ) callconv(.C) void;

    pub const Priority = extern enum {
        fifo = 0,
        lifo = 1,
    };

    next: ?*Task,
    data: usize,

    pub fn init(callback: Callback) Task {
        comptime std.debug.assert(@alignOf(Callback) >= 2);
        return Task{
            .next = undefined,
            .data = @ptrToInt(callback),
        };
    }

    pub fn getPriority(self: Task) Priority {
        return switch (@truncate(u1, self.data)) {
            0 => Priority.fifo,
            1 => Priority.lifo,
            else => unreachable,
        };
    }

    pub fn setPriority(noalias self: *Task, priority: Priority) void {
        const callback_ptr = self.data & ~@as(usize, 1);
        self.data = callback_ptr | @intCast(usize, @enumToInt(priority));
    }

    pub fn run(noalias self: *Task, noalias thread: *Thread) void {
        const callback = @intToPtr(Callback, self.data & ~@as(usize, 1));
        return (callback)(self, thread);
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

        pub fn pushFront(noalias self: *Batch, noalias task: *Task) void {
            return self.pushFrontMany(Batch.from(task));
        }

        pub fn pushBack(noalias self: *Batch, noalias task: *Task) void {
            return self.pushBackMany(Batch.from(task));
        }

        pub fn pushFrontMany(self: *Batch, batch: Batch) void {
            const batch_head = batch.head orelse return;
            if (self.head) |head| {
                batch.tail.next = head;
                self.head = batch_head;
            } else {
                self.* = batch;
            }
        }

        pub fn pushBackMany(self: *Batch, batch: Batch) void {
            const batch_head = batch.head orelse return;
            if (self.head) |head| {
                self.tail.next = batch_head;
                self.tail = batch.tail;
            } else {
                self.* = batch;
            }
        }

        pub fn popBack(noalias self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }

        pub fn iter(self: Batch) Iter {
            return Iter.from(self.head);
        }
    };

    pub const Iter = extern struct {
        task: ?*Task = null,

        fn from(task: ?*Task) Iter {
            return Iter{ .task = task };
        }

        pub fn next(self: *Iter) ?*Task {
            const task = self.task orelse return null;
            self.task = task.next;
            return task;
        }
    };
};
