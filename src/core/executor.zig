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

        const resume_result = starting_node.tryResumeThread(.{}) orelse {
            return StartError.EmptyWorkers;
        };

        return switch (resume_result) {
            .notified => StartError.EmptyWorkers,
            .resumed => std.debug.panic("Scheduler.start() with already spawned thread", .{}),
            .spawned => |worker| blk: {
                starting_node.pushBack(Task.Batch.from(starting_task));
                break :blk worker;
            },
        };
    }

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
            .worker_index = 0,
        };
    }

    pub const ThreadHandleIter = extern struct {
        node_iter: Node.Iter,
        worker_index: usize,

        pub fn next(noalias self: *ThreadHandleIter) Thread.Handle {
            var node = self.node_iter.current orelse return null;
            while (true) {

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

                node = self.node_iter.next() orelse return null;
                self.worker_index = 0;
            }
        }
    };
};

pub const Node = extern struct {
    pub const Cluster = extern struct {
        head: ?*Node,
        tail: *Node,

        pub fn init() Cluster {
            return Cluster{
                .head = null,
                .tail = undefined,
            };
        }

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
                cluster.tail.next = self.head;
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

    pub fn init(noalias self: *Node, workers: []Worker) void {
        self.workers_ptr = workers.ptr;
        self.workers_len = @truncate(u16, std.math.min(std.math.maxInt(u16), workers.len));
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
        noalias event_handler: *Thread.EventHandler,
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
            _ = event_handler.emit(thread, .@"yield", @enumToInt(Thread.EventYield.@"node_fifo"));
            head = @atomicLoad(*Task, &self.runq_head, .Monotonic);
            if (head != tail)
                return null;
        }

        self.pushBack(Task.Batch.from(stub));
        runq_tail.* = @atomicLoad(?*Task, &tail.next, .Acquire) orelse return null;
        return tail;
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
        return @intCast(u16, index - 1);
    }

    const IDLE_SHUTDOWN = ~@as(usize, 0);
    const IDLE_WAKING = 1 << 0;
    const IDLE_NOTIFIED = 1 << 1;
    const IDLE_WAKING_NOTIFIED = 1 << 2;

    const ResumeResult = union(enum) {
        notified: bool,
        resumed: *Thread,
        spawned: *Worker,
    };

    const ResumeContext = struct {
        is_waking: bool = false,
        is_remote: bool = false,
    };

    fn tryResumeThread(
        noalias self: *Node,
        context: ResumeContext,
    ) ?ResumeResult {
        const is_waking = context.is_waking;
        var resume_result: ?ResumeResult = undefined;
        var idle_queue = @atomicLoad(usize, &self.idle_queue, .Acquire);

        while (true) {
            var flags = @truncate(u8, idle_queue);
            var aba_tag = @truncate(u8, idle_queue >> 8);
            var worker_index = @truncate(u16, idle_queue >> 16);

            resume_result = null;
            if (idle_queue == IDLE_SHUTDOWN)
                std.debug.panic("Node.tryResumeThread() when shutdown", .{});
            
            if (!is_waking and (flags & IDLE_WAKING != 0)) {
                if (flags & IDLE_WAKING_NOTIFIED != 0)
                    break;
                flags |= IDLE_WAKING_NOTIFIED;
                resume_result = ResumeResult{ .notified = true };

            } else if (self.fromWorkerIndex(worker_index)) |worker| {
                flags |= IDLE_WAKING;
                const worker_ptr = @atomicLoad(usize, &worker.ptr, .Acquire);
                switch (Worker.Ref.decode(worker_ptr)) {
                    .handle => std.debug.panic("Node.tryResumeThread() found shutdown worker", .{}),
                    .node => std.debug.panic("Node.tryResumeThread() found spawning worker", .{}),
                    .thread => |thread| {
                        resume_result = ResumeResult{ .resumed = thread };
                        worker_index = @truncate(u16, thread.ptr);
                    },
                    .worker => |next_worker| {
                        resume_result = ResumeResult{ .spawned = worker };
                        worker_index = self.toWorkerIndex(next_worker);
                    },
                }
            } else if (flags & IDLE_NOTIFIED == 0) {
                flags |= IDLE_NOTIFIED;
                resume_result = ResumeResult{ .notified = false };
            } else {
                break;
            }

            if (is_waking) {
                flags &= ~@as(u8, IDLE_WAKING_NOTIFIED);
                if (flags & IDLE_WAKING == 0)
                    std.debug.panic("Node.tryResumeThread(is_waking) when not waking", .{});
                if (resume_result) |result| {
                    switch (result) {
                        .resumed, .spawned => flags &= ~@as(u8, IDLE_WAKING),
                        else => {},
                    }   
                }
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
                .Acquire,
            )) |updated_idle_queue| {
                idle_queue = updated_idle_queue;
                continue;
            }

            var new_worker = true;
            if (resume_result) |result| {
                switch (result) {
                    .notified => new_worker = false,
                    .resumed => |thread| {},
                    .spawned => |worker| {
                        const worker_ref = Worker.Ref{ .node = self };
                        @atomicStore(usize, &worker.ptr, worker_ref.encode(), .Monotonic);
                    },
                }
            }

            if (new_worker) {
                const threads_active = @atomicRmw(usize, &self.threads_active, .Add, 1, .Monotonic);
                if (threads_active == 0) {
                    _ = @atomicRmw(usize, &self.scheduler.nodes_active, .Add, 1, .Monotonic);
                }
            }

            break;
        }

        if (resume_result == null and !context.is_remote) {
            var nodes = self.iter();
            _ = nodes.next();
            while (nodes.next()) |remote_node| {
                resume_result = remote_node.tryResumeThread(.{
                    .is_waking = is_waking,
                    .is_remote = true,
                }) orelse continue;
                break;
            }
        }

        return resume_result;
    }

    fn undoResumeThread(
        noalias self: *Node,
        event_type: Thread.EventType,
        event_ptr: usize,
    ) void {
        var idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
        while (true) {
            var flags = @truncate(u8, idle_queue);
            var aba_tag = @truncate(u8, idle_queue >> 8);
            var worker_index = @truncate(u16, idle_queue >> 16);

            if (idle_queue == IDLE_SHUTDOWN)
                std.debug.panic("Node.undoResumeThread() when shutdown", .{});
            if (flags & IDLE_WAKING == 0)
                std.debug.panic("Node.undoResumeThread() when not waking", .{});

            switch (event_type) {
                .@"spawn" => {
                    const worker = @intToPtr(*Worker, event_ptr);
                    const next_worker = self.fromWorkerIndex(worker_index);
                    const worker_ref = Worker.Ref{ .worker = next_worker };
                    @atomicStore(usize, &worker.ptr, worker_ref.encode(), .Monotonic);
                    worker_index = self.toWorkerIndex(worker);
                },
                .@"resume" => {
                    const thread = @intToPtr(*Thread, event_ptr);
                    thread.ptr = worker_index;
                    worker_index = self.toWorkerIndex(thread.worker);
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
            if (is_waking and (flags & IDLE_WAKING_NOTIFIED != 0)) {
                flags &= ~@as(u8, IDLE_WAKING_NOTIFIED);
                is_notified = true;
            } else if (flags & IDLE_NOTIFIED != 0) {
                flags &= ~@as(u8, IDLE_NOTIFIED);
                is_notified = true;
            } else {
                if (is_waking)
                    flags &= ~@as(u8, IDLE_WAKING);
                thread.ptr = worker_index;
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
                thread.ptr = old_ptr;
                return null;
            }

            const threads_active = @atomicRmw(usize, &self.threads_active, .Sub, 1, .Monotonic);
            if (threads_active == 1) {
                const nodes_active = @atomicRmw(usize, &self.scheduler.nodes_active, .Sub, 1, .Monotonic);
                if (nodes_active == 1) {
                    self.shutdown(thread, @intToPtr(*Thread.EventHandler, old_ptr));
                    return true;
                }
            }

            return false;
        }
    }

    fn shutdown(
        noalias self: *Node,
        noalias initiator: *Thread,
        noalias event_handler: *Thread.EventHandler,
    ) void {
        var idle_threads: ?*Thread = null;
        var nodes = self.iter();
        while (nodes.next()) |node| {
            var idle_workers: u16 = 0;
            var idle_queue = @atomicRmw(usize, &node.idle_queue, .Xchg, IDLE_SHUTDOWN, .Acquire);

            if (idle_queue == IDLE_SHUTDOWN)
                std.debug.panic("Node.shutdown() when already shutdown", .{});
            if (idle_queue & IDLE_WAKING != 0)
                std.debug.panic("Node.shutdown() when a thread is waking", .{});
            if (idle_queue & (IDLE_NOTIFIED | IDLE_WAKING_NOTIFIED) != 0)
                std.debug.panic("Node.shutdown() when idle queue notified", .{});

            const workers = node.workers_ptr;
            var worker_index = @truncate(u16, idle_queue >> 16);
            while (worker_index != 0) {
                const worker = &workers[worker_index - 1];
                switch (Worker.Ref.decode(@atomicLoad(usize, &worker.ptr, .Acquire))) {
                    .node => std.debug.panic("Node.shutdown() when worker is spawning", .{}),
                    .handle => std.debug.panic("Node.shutdown() when worker is already shutdown", .{}),
                    .worker => |next_worker| {
                        worker_index = node.toWorkerIndex(next_worker);
                        const worker_ref = Worker.Ref{ .handle = null };
                        @atomicStore(usize, &worker.ptr, worker_ref.encode(), .Monotonic);
                    },
                    .thread => |thread| {
                        thread.ptr = @ptrToInt(idle_threads);
                        idle_threads = thread;
                        const worker_ref = Worker.Ref{ .handle = thread.handle };
                        @atomicStore(usize, &worker.ptr, worker_ref.encode(), .Monotonic);
                    },
                }
            }

            if (idle_workers != node.workers_len)
                std.debug.panic("Node.shutdown() when all workers weren't idle", .{});
        }

        while (idle_threads) |idle_thread| {
            const thread = idle_thread;
            thread.worker = null;
            idle_threads = @intToPtr(?*Thread, thread.ptr);

            const notified = event_handler.emit(initiator, .@"resume", @ptrToInt(thread));
            std.debug.assert(notified);
        }
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
            .ptr = undefined,
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

    pub const EventFn = fn(
        noalias *EventHandler,
        noalias *Thread,
        EventType,
        usize,
    ) callconv(.C) bool;

    pub const EventHandler = extern struct {
        event_fn: EventFn,

        pub fn init(event_fn: EventFn) EventHandler {
            return EventHandler{ .event_fn = event_fn };
        }

        pub fn emit(
            noalias self: *EventHandler,
            noalias thread: *Thread,
            event_type: EventType,
            event_ptr: usize,
        ) bool {
            return (self.event_fn)(self, thread, event_type, event_ptr);
        }
    };

    pub const EventType = extern enum {
        @"run" = 0,
        @"spawn" = 1,
        @"resume" = 2,
        @"yield" = 3,
    };

    pub const EventYield = extern enum {
        @"poll_fifo" = 0,
        @"poll_lifo" = 1,
        @"node_fifo" = 2,
        @"steal_fifo" = 3,
        @"steal_lifo" = 4,
    };

    pub const Poll = extern enum {
        @"shutdown" = 0,
        @"suspend" = 1,
    };

    pub fn poll(
        noalias self: *Thread,
        noalias event_handler: *EventHandler,
    ) Poll {
        var worker = self.worker orelse return Poll.@"shutdown";
        const node = self.node;
        var is_waking = true;

        self.ptr = @ptrToInt(event_handler);
        while (true) {
            var polled_node = false;
            const next_task = blk: {
                if (self.pollSelf(event_handler)) |task| {
                    break :blk task;
                }

                var nodes = node.iter();
                while (nodes.next()) |target_node| {
                    if (self.pollNode(target_node, event_handler)) |task| {
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
                            .worker, .node => {},
                            .handle => std.debug.panic("Worker {} with thread handle set when stealing", .{current_index}),
                            .thread => |target_thread| {
                                if (target_thread == self)
                                    continue;
                                if (self.pollThread(target_thread, event_handler)) |task|
                                    break :blk task;
                            }
                        }
                    }
                }

                break :blk null;
            };

            if (next_task) |task| {
                if (is_waking or polled_node)
                    self.resumeThread(node, is_waking);
                is_waking = false;

                const executed = event_handler.emit(self, .@"run", @ptrToInt(task));
                if (!executed)
                    self.schedule(Task.Batch.from(task));

                continue;
            }

            if (node.trySuspendThread(self, worker, is_waking)) |last_in_scheduler| {
                if (last_in_scheduler)
                    return Poll.@"shutdown";
                return Poll.@"suspend";
            }

            worker = self.worker orelse return Poll.@"shutdown";
        }
    }

    fn pollSelf(
        noalias self: *Thread,
        noalias event_handler: *EventHandler,
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
            _ = event_handler.emit(self, .@"yield", @enumToInt(EventYield.@"poll_lifo"));
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
            _ = event_handler.emit(self, .@"yield", @enumToInt(EventYield.@"poll_fifo"));
        }

        return null;
    }

    fn pollThread(
        noalias self: *Thread,
        noalias target: *Thread,
        noalias event_handler: *EventHandler,
    ) ?*Task {
        const tail = self.runq_tail;
        const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        if (tail != head)
            std.debug.panic("Thread.pollThread() with non-empty ({}) runq", .{tail -% head});
        
        var target_head = @atomicLoad(usize, &target.runq_head, .Acquire);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.runq_tail, .Acquire);
            const target_size = target_tail -% target_head;
            if (target_size > target.runq_buffer.len)
                std.debug.panic("Thread.pollThread() with invalid target runq size {}", .{target_size});

            var steal = target_size - (target_size / 2);
            if (steal == 0) {
                const target_next = @atomicLoad(?*Task, &target.runq_next, .Monotonic) orelse return null;
                _ = event_handler.emit(self, .@"yield", @enumToInt(EventYield.@"steal_lifo"));
                _ = @cmpxchgWeak(
                    ?*Task,
                    &target.runq_next,
                    target_next,
                    null,
                    .Acquire,
                    .Monotonic,
                ) orelse return target_next;
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
                _ = event_handler.emit(self, .@"yield", @enumToInt(EventYield.@"steal_fifo"));
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
        noalias event_handler: *EventHandler,
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
        var first_task = node.popFront(self, &node_tail, event_handler);
        var next_task = node.popFront(self, &node_tail, event_handler);

        const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        const tail = self.runq_tail;
        const size = tail -% head;
        if (size > self.runq_buffer.len)
            std.debug.panic("Thread.pollNode() with invalid runq size of {}", .{size});

        var new_tail = tail;
        while (new_tail -% head < self.runq_buffer.len) {
            const task = node.popFront(self, &node_tail, event_handler) orelse break;
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

    pub fn schedule(noalias self: *Thread, batch: Task.Batch) void {
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

        self.resumeThread(node, false);
    }

    fn resumeThread(
        noalias self: *Thread,
        noalias node: *Node,
        is_waking: bool,
    ) void {
        if (node.tryResumeThread(.{ .is_waking = is_waking })) |resume_result| {
            var event_type: EventType = undefined;
            const event_ptr = switch (resume_result) {
                .notified => return,
                .spawned => |worker| blk: {
                    event_type = .@"spawn";
                    break :blk @ptrToInt(worker);
                },
                .resumed => |thread| blk: {
                    event_type = .@"resume";
                    break :blk @ptrToInt(thread);
                },
            };

            const event_handler = @intToPtr(*EventHandler, self.ptr);
            const success = event_handler.emit(self, event_type, event_ptr);
            if (success)
                return;

            const resume_node = switch (event_type) {
                .@"resume" => @intToPtr(*Thread, event_ptr).node,
                .@"spawn" => blk: {
                    const worker = @intToPtr(*Worker, event_ptr);
                    const worker_ptr = @atomicLoad(usize, &worker.ptr, .Monotonic);
                    break :blk switch (Worker.Ref.decode(worker_ptr)) {
                        .node => |worker_node| worker_node,
                        .thread, .worker, .handle => std.debug.panic("Thread.resumeThread() with invalid worker", .{}),
                    };
                },
                else => unreachable,
            };

            resume_node.undoResumeThread(event_type, event_ptr);
        }
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
