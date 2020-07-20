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

    pub fn start(
        noalias self: *Scheduler,
        noalias starting_node: *Node,
        noalias starting_task: *Task,
    ) !*Worker {
        if (self.nodes.isEmpty()) {
            return error.EmptyNodes;
        }

        var has_starting_node = false;
        var nodes = self.nodes.iter();
        while (nodes.next()) |node| {
            has_starting_node = has_starting_node || (node == starting_node);
            node.start(self);
        }

        if (!has_starting_node) {
            return error.InvalidStartingNode;
        }

        const resumt_result = starting_node.tryResumeThread(.{}) orelse {
            return error.EmptyWorkers;
        };

        switch (resume_result) {
            .notified => std.debug.panic("Scheduler.start() with waking thread", .{}),
            .resume => std.debug.panic("Scheduler.start() with already spawned thread", .{}),
            .spawn => |worker| {
                starting_node.pushBack(Task.Batch.from(starting_task));
                return worker;
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
        tail: *Cluster,

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
            return self.node == null;
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

    fn pushBack(noalias self: *Node, batch: Task.Batch) {
        const head = batch.head orelse return;
        const tail = batch.tail;
        const prev = @atomicRmw(*Task, &self.runq_head, .Xchg, tail, .AcqRel);
        @atomicStore(?*Task, &prev.next, head, .Release);
    }

    fn popFront(noalias self: *Node, noalias runq_tail: **Task) ?*Task {
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

        const head = @atomicLoad(*Task, &self.head, .Monotonic);
        if (head != tail)
            return null;

        self.pushBack(Batch.from(stub));
        runq_tail.* = @atomicLoad(?*Task, &tail.next, .Acquire) orelse return null;
        return tail;
    }

    const ResumeResult = union(enum) {
        notified: void,
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
        var idle_queue = @atomicLoad(usize, &self.idle_queue, .Acquire);

        while (true) {
            if (idle_queue == IDLE_SHUTDOWN)
                std.debug.panic("Node.tryResumeThread() when shutdown", .{});
        }

        if (!context.is_remote) {
            var nodes = self.iter();
            _ = nodes.next();
            while (nodes.next()) |remote_node| {
                if (remote_node.tryResumeThread(.{
                    .is_waking = is_waking,
                    .is_remote = true,
                })) |resume_result| {
                    return resume_result;
                }
            }
        }

        return null;
    }

    fn undoResumeThread(
        noalias self: *Node,
        ptr_type: Thread.SchedulePtr,
        ptr: usize,
    ) void {
        var idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
    }

    const SuspendResult = enum {
        suspended,
        shutdown,
    };

    fn trySuspendThread(
        noalias self: *Node,
        noalias thread: *Thread,
        is_waking: bool,
    ) ?SuspendResult {
        
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
    pub const Handle = ?*const u32;

    pub const ScheduleFn = fn(SchedulePtr, usize) callconv(.C) bool;
    pub const SchedulePtr = extern enum {
        worker,
        thread,
    };

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
            std.debug.panic("Thread.deinit() with {} pending runq tasks", .{tail -% head });
    }

    fn resumeThread(
        noalias self: *Thread,
        noalias node: *Node,
        is_waking: bool,
    ) void {
        if (node.tryResumeThread(.{ .is_waking = is_waking })) |resume_result| {
            var schedule_ptr: SchedulePtr = undefined;
            const ptr = switch (resume_result) {
                .notified => return,
                .spawn => |worker| blk: {
                    schedule_ptr = .worker;
                    break :blk @ptrToInt(worker);
                },
                .resume => |thread| blk: {
                    schedule_ptr = .thread;
                    break :blk @ptrToInt(thread);
                },
            };

            const schedule_fn = @intToPtr(ScheduleFn, self.ptr);
            const scheduled = (schedule_fn)(schedule_ptr, ptr);
            if (!scheduled)
                node.undoResumeThread(schedule_ptr, ptr);
        }
    }

    pub fn poll(
        noalias self: *Thread,
        schedule_fn: ScheduleFn,
    ) bool {
        const worker = self.worker orelse return false;
        self.ptr = @ptrToInt(schedule_fn);
        const node = self.node;
        var is_waking = true;

        while (true) {
            var polled_node = false;
            const next_task = blk: {
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
                            .worker, .node => {},
                            .handle => std.debug.panic("Worker {} with thread handle set when stealing", .{current_index}),
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
                if (is_waking or polled_node)
                    self.resumeThread(node, is_waking);
                
                is_waking = false;
                task.run(self);
                continue;
            }

            if (node.trySuspendThread(self, is_waking)) |suspend_result| {
                return switch (suspend_result) {
                    .suspended => true,
                    .shutdown => false,
                };
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
        var head = @atomicStore(usize, &self.runq_head, .Monotonic);
        while (true) {
            const size = tail -% head;
            if (size == 0)
                break;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.pollSelf() with invalid runq size {}", .{size}); 

            head = @cmpxchgWeak(
                usize,
                &self.head,
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
            if (target_size > target.runq_buffer.len)
                std.debug.panic("Thread.pollThread() with invalid target runq size {}", .{target_size});

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
        var first_task = node.popFront(&node_tail);
        var next_task = node.popFront(&node_tail);

        const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        const tail = self.runq_tail;
        const size = tail -% head;
        if (size > self.runq_buffer.len)
            std.debug.panic("Thread.pollNode() with invalid runq size of {}", .{size});

        var new_tail = tail;
        while (new_tail -% head < self.runq_buffer.len) {
            const task = node.popFront(&node_tail) orelse break;
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
            @atomicStore(?*Task, &self.runq_tail, new_tail, .Release);
        return first_task;
    }

    pub fn schedule(noalias self: *Thread, batch: Batch) void {
        var tasks = batch;
        const node = self.node;
        const tail = self.runq_tail;
        var new_tail = tail;

        next_task: while (true) {
            var task = tasks.pop() orelse break;
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
                    };

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
};

pub const Task = extern struct {
    pub const Callback = fn(*Task, *Thread) callconv(.C) void;

    pub const Priority = extern enum {
        fifo = 0,
        lifo = 1,
    };

    next: ?*Task,
    data: usize,

    pub fn init(priority: Priority, callback: Callback) Task {
        return Task{
            .next = undefined,
            .data = @ptrToInt(callback) | @enumToInt(priority),
        };
    }

    pub fn getPriority(self: Task) Priority {
        return switch (@truncate(u1, self.data)) {
            0 => Priority.fifo,
            1 => Priority.lifo,
            else => unreachable,
        };
    }

    pub fn run(noalias self: *Task, noalias thread: *Thread) void {
        const callback = @intToPtr(Callback, self.data & ~@as(usize, 1));
        return (callback)(self, thread);
    }

    pub const Batch = extern struct {
        head: ?*Task,
        tail: *Task,

        pub fn init() Batch {
            return Batch{
                .head = null,
                .tail = undefined,
            };
        }

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
    }
};
