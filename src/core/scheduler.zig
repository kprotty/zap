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
const zap = @import("./zap");

pub const Task = extern struct {
    next: ?*Task = undefined,
    continuation: usize,

    pub const Callback = fn (*Task) callconv(.C) void;

    pub fn fromFrame(frame: anyframe) Task {
        return Task{ .continuation = @ptrToInt(frame) };
    }

    pub fn fromCallback(callback: Callback) Task {
        return Task{ .continuation = @ptrToInt(callback) | 1 };
    }

    pub fn execute(self: *Task) void {
        @setRuntimeSafety(false);
        if (self.continuation & 1 != 0)
            return @intToPtr(Callback, self.continuation & ~@as(usize, 1))(self);
        resume @intToPtr(anyframe, self.continuation);
    }

    pub const Batch = struct {
        head: ?*Task = null,
        tail: *Task = undefined,

        pub fn isEmpty(self: Batch) bool {
            return self.head == null;
        }

        pub fn from(task: ?*Task) Batch {
            if (task) |task_ref|
                task_ref.next = null;
            return Batch{
                .head = task,
                .tail = task orelse undefined,
            };
        }

        pub fn push(self: *Batch, task: *Task) void {
            return self.pushBack(task);
        }

        pub fn pushBack(self: *Batch, task: *Task) void {
            return self.pushBackMany(from(task));
        }

        pub fn pushFront(self: *Batch, task: *Task) void {
            return self.pushFrontMany(from(task));
        }

        pub fn pushBackMany(self: *Batch, other: Batch) void {
            if (other.isEmpty())
                return;
            if (self.isEmpty()) {
                self.* = other;
            } else {
                self.tail.next = other.head;
                self.tail = other.tail;
            }
        }

        pub fn pushFrontMany(self: *Batch, other: Batch) void {
            if (other.isEmpty())
                return;
            if (self.isEmpty()) {
                self.* = other;
            } else {
                other.tail.next = self.head;
                self.head = other.head;
            }
        }

        pub fn pop(self: *Batch) ?*Task {
            return self.popFront();
        }

        pub fn popFront(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }
    };
};

pub const Thread = extern struct {
    runq_head: usize = 0,
    runq_tail: usize = 0,
    runq_overflow: ?*Task = null,
    runq_buffer: [256]*Task = undefined,
    local_head: *Task,
    local_tail: Task,
    worker: *Worker,
    ptr: usize,
    
    pub fn init(self: *Thread, worker: *Worker) void {
        self.* = Thread{
            .local_head = &self.local_tail,
            .local_tail = Task{
                .next = null,
                .continuation = @ptrToInt(&self.local_tail),
            },
            .worker = worker,
            .ptr = @ptrToInt(pool),
        };
    }

    pub fn pushLocal(self: *Therad, batch: Task.Batch) void {
        if (batch.isEmpty())
            return;
        self.pushOnlyLocal(batch.head, batch.tail);
    }

    pub fn push(self: *Thread, tasks: Task.Batch) void {
        var batch = tasks;
        var tail = self.runq_tail;
        var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        while (!batch.isEmpty()) {

            const size = tail -% head;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.push() with invalid runq size of {}", .{size});

            var remaining = self.runq_buffer.len - size;
            if (remaining != 0) {
                while (remaining != 0) : (remaining -= 1) {
                    const task = batch.pop() orelse break;
                    const buffer_ptr = &self.runq_buffer[tail % self.runq_buffer.len];
                    @atomicStore(*Task, buffer_ptr, task, .Unordered);
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
                .Acquire,
                .Monotonic,
            )) |updated_head| {
                head = updated_head;
                continue;
            }

            defer batch = Task.Batch{};
            batch.pushFrontMany(blk: {
                var overflowed = Task.Batch{};
                while (head != new_head) : (head +%= 1) {
                    const buffer_ptr = &self.runq_buffer[head % self.runq_buffer.len];
                    const task = @atomicLoad(*Task, buffer_ptr, .Unordered);
                    overflowed.push(task);
                }
                break :blk overflowed;
            });

            var runq_overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
            while (true) {
                batch.tail.next = runq_overflow;

                if (runq_overflow == null) {
                    @atomicStore(?*Task, &self.runq_overflow, batch.head, .Release);
                    break;
                }

                runq_overflow = @cmpxchgWeak(
                    ?*Task,
                    &self.runq_overflow,
                    runq_overflow,
                    batch.head,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }
        }
    }

    fn inject(self: *Thread, run_queue: ?*Task) void {
        var runq: ?*Task = runq_queue orelse return;
        var tail = self.runq_tail;
        var head = @atomicLoad(usize, &self.runq_head, .Monotonic);

        const size = tail -% head;
        if (size > self.runq_buffer.len)
            std.debug.panic("Thread.inject() with invalid runq size of {}", .{size});
        if (size != 0)
            std.debug.panic("Thread.inject() when not empty with runq size of {}", .{size});

        var remaining: usize = self.runq_buffer.len;
        while (remaining != 0) : (remaining -= 1) {
            const task = runq orelse break;
            const buffer_ptr = &self.runq_buffer[tail % self.runq_buffer.len];
            @atomicStore(*Task, buffer_ptr, task, .Unordered);
            runq = task.next;
            tail +%= 1;
        }

        @atomicStore(usize, &self.runq_tail, tail, .Release);
        if (runq == null)
            return;

        const runq_overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
        if (runq_overflow != null) {
            std.debug.panic("Thread.inject() when runq overflow is not empty", .{});
        } else {
            @atomicStore(?*Task, &self.runq_overflow, runq, .Release);
        }
    }

    fn pushOnlyLocal(self: *Thread, head: ?*Task, tail: *Task) void {
        const prev = @atomicRmw(*Task, &self.local_head, .Xchg, tail, .AcqRel);
        @atomicStore(?*Task, &prev.next, head, .Release);
    }

    fn pollOnlyLocal(self: *Thread) ?*Task {
        @setRuntimeSafety(false);
        const stub_ptr = &self.local_runq;
        const tail_ptr = @ptrCast(**Task, &self.local_runq.continuation);
        
        var tail = tail_ptr.*;
        var next = @atomicLoad(?*Task, &tail.next, .Acquire);

        if (tail == stub_ptr) {
            tail = next orelse break :blk;
            tail_ptr.* = tail;
            next = @atomicLoad(?*Task, &tail.next, .Acquire);
        }

        if (next) |new_tail| {
            tail_ptr.* = new_tail;
            return tail;
        }

        var wait_on_push: u4 = 8;
        while (true) {
            const head = @atomicLoad(*Task, &self.local_head, .Monotonic);
            if (tail == head)
                break;
            if (wait_on_push == 0)
                return null;
            wait_on_push -= 1;
            spinLoopHint();
        }

        stub_ptr.next = null;
        self.pushOnlyLocal(stub_ptr, stub_ptr);

        next = @atomicLoad(?*Task, &tail.next, .Acquire);
        if (next) |new_tail| {
            tail_ptr.* = new_tail;
            return tail;
        }

        return null;
    }

    pub fn pollLocal(self: *Thread) ?*Task {
        if (self.pollOnlyLocal()) |task| {
            return task;
        }

        var tail = self.runq_tail;
        var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        while (true) {

            const size = tail -% head;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.pollLocal() with invalid runq size of {}", .{size});
            if (size == 0)
                break;

            head = @cmpxchgWeak(
                usize,
                &self.runq_head,
                head,
                head +% 1,
                .Acquire,
                .Monotonic,
            ) orelse {
                const buffer_ptr = &self.runq_buffer[head % self.runq_buffer.len];
                return @atomicLoad(*Task, buffer_ptr, .Unordered);
            };
        }

        var runq_overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
        while (runq_overflow) |task| {
            runq_overflow = @cmpxchgWeak(
                usize,
                &self.runq_overflow,
                task,
                null,
                .Acquire,
                .Monotonic,
            ) orelse {
                self.inject(task.next);
                return task;
            };
        }

        if (self.pollOnlyLocal()) |task| {
            return task;
        }

        return null;
    }

    pub fn pollGlobal(noalias self: *Thread, noalias pool: *Pool) ?*Task {
        if (pool == self.pool) {
            var run_queue = @atomicLoad(?*Task, &pool.local_runq, .Monotonic);
            while (run_queue) |task| {
                run_queue = @cmpxchgWeak(
                    ?*Task,
                    &pool.local_runq,
                    run_queue,
                    null,
                    .Acquire,
                    .Monotonic,
                ) orelse {
                    self.inject(task.next);
                    return task;
                };
            }
        }

        var run_queue = @atomicLoad(?*Task, &pool.shared_runq, .Monotonic);
        while (run_queue) |task| {
            run_queue = @cmpxchgWeak(
                ?*Task,
                &pool.shared_runq,
                run_queue,
                null,
                .Acquire,
                .Monotonic,
            ) orelse {
                self.inject(task.next);
                return task;
            };
        }

        return null;
    }

    pub fn pollSteal(noalias self: *Thread, noalias target: *Thread) ?*Task {
        var tail = self.runq_tail;
        var head = @atomicLoad(usize, &self.runq_head, .Monotonic);

        const size = tail -% head;
        if (size > self.runq_buffer.len)
            std.debug.panic("Thread.pollSteal() with invalid runq of size {}", .{size});
        if (size != 0)
            std.debug.panic("Thread.pollSteal() when runq not empty with size of {}", .{size});

        var target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.runq_tail, .Acquire);

            const target_size = target_tail -% target_head;
            if (target_size > self.runq_buffer.len) {
                spinLoopHint();
                target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                continue;
            }

            var steal = target_size - (target_size / 2);
            if (steal == 0) {
                if (@atomicLoad(?*Task, &target.runq_overflow, .Monotonic)) |task| {
                    _ = @cmpxchgWeak(
                        ?*Task,
                        &target.runq_overflow,
                        task,
                        null,
                        .Acquire,
                        .Monotonic,
                    ) orelse {
                        self.inject(task.next);
                        return task;
                    };
                } else {
                    break;
                }

                spinLoopHint();
                target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                continue;
            }

            var new_tail = tail;
            var new_target_head = target_head;
            var first_task: ?*Task = null;

            while (steal != 0) : (steal -= 1) {
                const target_buffer_ptr = &target.runq_buffer[new_target_head % target.runq_buffer.len];
                const task = @atomicLoad(*Task, target_buffer_ptr, .Unordered);
                new_target_head +%= 1;

                if (first_task == null) {
                    first_task = task;
                } else {
                    const buffer_ptr = &self.runq_buffer[new_tail % self.runq_buffer.len];
                    @atomicStore(*Task, buffer_ptr, task, .Unordered);
                    new_tail +%= 1;
                }
            }

            if (@cmpxchgWeak(
                usize,
                &target.runq_head,
                target_head,
                new_target_head,
                .Acquire,
                .Monotonic,
            )) |updated_target_head| {
                target_head = updated_target_head;
                continue;
            }

            if (new_tail != tail)
                @atomicStore(usize, &self.runq_tail, new_tail, .Release);
            return first_task;
        }

        return null;
    }
};

pub const Pool = extern struct {
    num_workers: u32,
    local_runq: ?*Task,
    shared_runq: ?*Task,
    idle_queue: usize,

    const IDLE_MARKED = 1;
    const IDLE_SHUTDOWN = ~@as(usize, 0);
    
    const MAX_WORKERS = (std.math.maxInt(u32) >> 8) - 1;

    fn init(self: *Pool, worker_count: u32, is_blocking: bool) void {
        const num_workers = std.math.min(worker_count, MAX_WORKERS);

        self.* = Pool{
            .num_workers = (num_workers << 1) | @boolToInt(is_blocking),
            .local_runq = null,
            .shared_runq = null,
            .idle_queue = 0,
        };
        
        self.idle_queue = blk: {
            const workers = self.getWorkers();
            for (workers) |*worker, index|
                worker.ptr = (Worker.Ptr{ .idle = index }).toUsize();
            break :blk ((workers.len + 1) << 8);
        };
    }

    fn deinit(self: *Pool) void {
        const local_runq = @atomicLoad(?*Task, &self.local_runq, .Monotonic);
        if (local_runq != null)
            std.debug.panic("Pool.deinit() when local_runq is not empty", .{});

        const shared_runq = @atomicLoad(?*Task, &self.shared_runq, .Monotonic);
        if (shared_runq != null)
            std.debug.panic("Pool.deinit() when shared_runq is not empty", .{});

        const idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
        if (idle_queue != IDLE_SHUTDOWN)
            std.debug.panic("Pool.deinit() when idle_queue is not shutdown", .{});
    }

    pub fn isBlocking(self: Pool) bool {
        return self.num_workers & 1 != 0;
    }

    pub fn getNode(self: *Pool) *Node {
        if (self.isBlocking())
            return @fieldParentPtr(Node, "blocking_pool", self);
        return @fieldParentPtr(Node, "non_blocking_pool", self);
    }

    pub fn getWorkers(self: *Pool) []Worker {
        const num_workers = self.num_workers;
        const workers_len = num_workers >> 1;

        if (num_workers & 1 == 0) {
            const node = @fieldParentPtr(Node, "non_blocking_pool", self);
            return node.workers[0..workers_len];
        }

        const node = @fieldParentPtr(Node, "blocking_pool", self);
        const non_blocking_workers_len = node.non_blocking_pool.num_workers >> 1;
        return node.workers[non_blocking_workers_len..][0..workers_len];
    }

    pub fn push(self: *Pool, batch: Task.Batch) void {
        return self.pushBatch(&self.shared_runq, batch);
    }

    pub fn pushLocal(self: *Pool, batch: Task.Batch) void {
        return self.pushBatch(&self.local_runq, batch);
    }

    fn pushBatch(run_queue_ptr: *?*Task, batch: Task.Batch) void {
        if (batch.isEmpty())
            return;

        var run_queue = @atomicLoad(?*Task, run_queue_ptr, .Monotonic);
        while (true) {
            batch.tail.next = run_queue;
            run_queue = @cmpxchgWeak(
                ?*Task,
                run_queue_ptr,
                run_queue,
                batch.head,
                .Release,
                .Monotonic,
            ) orelse break;
        }
    }

    pub const Schedule = struct {
        pool: usize,
        ptr: usize,

        pub const Result = union(enum) {
            notified: void,
            spawned: *Worker,
            resumed: *Thread,
        };

        fn from(
            pool: *Pool,
            result: Result,
            first_in_node: bool,
            first_in_scheduler: bool,
        ) Schedule {
            return Schedule{
                .pool = @ptrToInt(pool)
                    | (@boolToInt(first_in_node) << 1)
                    | (@boolToInt(first_in_scheduler) << 0),
                .ptr = switch (result) {
                    .notified => 0,
                    .spawned => |worker| @ptrToInt(worker) | 1,
                    .resumed => |thread| @ptrToInt(thread),
                },
            };
        }

        pub fn wasFirstInNode(self: Schedule) bool {
            return (self.pool & (1 << 1)) != 0;
        }

        pub fn wasFirstInScheduler(self: Schedule) bool {
            return (self.pool & (1 << 0)) != 0;
        }

        pub fn getPool(self: Schedule) *Pool {
            @setRuntimeSafety(false);
            return @intToPtr(*Pool, self.pool & ~@as(usize, 0b11)); 
        }

        pub fn getResult(self: Schedule) Result {
            @setRuntimeSafety(false);
            if (self.ptr == 0)
                return Result{ .notified = {} };
            if (self.ptr & 1 != 0)
                return Result{ .spawned = @intToPtr(*Worker, self.ptr & ~@as(usize, 1)) };
            return Result{ .resumed = @intToPtr(*Thread, self.ptr) };
        }

        pub fn undo(self: Schedule) void {
            return self.getPool().undoResumeThread(self.getResult());
        }
    };

    pub fn tryResumeThread(self: *Pool) ?Schedule {
        return self.resumeThread(.{ .check_remote = true });
    }

    pub fn tryResumeLocalThread(self: *Pool) ?Schedule {
        return self.resumeThread(.{});
    }

    const ResumeOptions = struct {
        was_waking: bool = false,
        check_remote: bool = false,
    };

    fn resumeThread(self: *Pool, options: ResumeOptions) ?Schedule {
        const workers = self.getWorkers();
        var idle_queue = @atomicLoad(usize, &self.idle_queue, .Acquire);

        while (true) {
            if (idle_queue == IDLE_SHUTDOWN)
                std.debug.panic("Pool.resumeThread() when already shutdown", .{});

            var worker_index = idle_queue >> 8;
            var new_result: Schedule.Result = undefined;
            var new_idle_queue = idle_queue & (~@as(u8, 0) << 1);

            if (worker_index != 0) {
                if (!options.was_waking and (idle_queue & IDLE_MARKED != 0))
                    break;

                worker_index -= 1;
                const worker = &workers[worker_index];
                const ptr = @atomicLoad(usize, &worker.ptr, .Acquire);

                switch (Worker.Ptr.fromUsize(ptr)) {
                    .idle => |next_index| {
                        new_result = Schedule.Result{ .spawned = worker };
                        new_idle_queue = (next_index << 8) | @boolToInt(next_index != 0);
                    },
                    .spawning => {
                        spinLoopHint();
                        idle_queue = @atomicLoad(usize, &self.idle_queue, .Acquire);
                        continue;
                    },
                    .spawned => |thread| {
                        const next_index = @atomicLoad(usize, &thread.ptr, .Unordered);
                        if (next_index > MAX_WORKERS) {
                            spinLoopHint();
                            idle_queue = @atomicLoad(usize, &self.idle_queue, .Acquire);
                            continue;
                        } else {
                            new_result = Schedule.Result{ .resumed = thread };
                            new_idle_queue = next_index | @boolToInt(next_index != 0);
                        }
                    },
                    .shutdown => {
                        std.debug.panic("Pool.resumeThread() when worker {} already shutdown", .{worker_index});
                    },
                }
            } else if (idle_queue & IDLE_MARKED != 0) {
                break;
            } else {
                new_result = Schedule.Result{ .notified = {} };
                new_idle_queue |= IDLE_MARKED;
            }

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

            var was_notified = false;
            switch (new_result) {
                .notified => {
                    was_notified = true;
                },
                .spawned => |worker| {
                    const worker_ptr = (Worker.Ptr{ .spawning = pool }).toUsize();
                    @atomicStore(usize, &worker.ptr, worker_ptr, .Release);
                },
                .resumed => |thread| {
                    const thread_ptr = @ptrToInt(self) | @boolToInt(true);
                    @atomicStore(usize, &thread.ptr, thread_ptr, .Unordered);
                },
            }

            const node = self.getNode();
            const first_in_node = !was_notified and blk: {
                const active_threads = @atomicRmw(usize, &node.active_threads, .Add, 1, .Monotonic);
                break :blk (active_threads == 0);
            };
            const first_in_scheduler = first_in_node and blk: {
                const scheduler = node.getScheduler();
                const active_nodes = @atomicRmw(usize, &scheduler.active_nodes, .Add, 1, .Monotonic);
                break :blk (active_nodes == 1);
            };

            return Schedule.from(
                self,
                new_result,
                first_in_node,
                first_in_scheduler,
            );
        }

        if (options.check_remote) {
            const node = self.getNode();
            const is_blocking = self.isBlocking();

            var nodes = node.iter();
            _ = nodes.next();
            while (nodes.next()) |remote_node| {
                const pool = switch (is_blocking) {
                    true => &remote_node.blocking_pool,
                    else => &remote_node.non_blocking_pool,
                };
                if (pool.tryResumeLocalThread()) |schedule|
                    return scheudle;
            }
        }

        return null;
    }

    fn undoResumeThread(self: *Pool, result: Schedule.Result) void {
        switch (result) {
            .notified => return,
            .spawned, .resumed => {
                const node = self.getNode();
                if (@atomicRmw(usize, &node.active_threads, .Sub, 1, .Monotonic) == 0) {
                    const scheduler = node.getScheduler();
                    _ = @atomicRmw(usize, &scheduler.active_nodes, .Sub, 1, .Monotonic);
                }
            },
        }

        var idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
        while (true) {
            if (idle_queue == IDLE_SHUTDOWN)
                std.debug.panic("Pool.undoResumeThread() when already shutdown", .{});
            if (idle_queue & IDLE_MARKED == 0)
                std.debug.panic("Pool.undoResumeThread() when not waking", .{});

            var worker_index = idle_queue >> 8;
            var aba_tag = @truncate(u7, idle_queue >> 1);

            switch () {
                @compileError("TODO");
            }

            idle_queue = @cmpxchgWeak(
                        usize,
                        &self.idle_queue,
                        idle_queue,
                        (aba_tag +% 1) | (worker_index << 8),
                        .Release,
                        .Monotonic,
                    ) orelse return;
        }
    }
};

pub const Worker = extern struct {
    ptr: usize,

    const Ptr = union(enum) {
        idle: u32,
        spawning: *Pool,
        spawned: *Thread,
        shutdown: ?Thread.Handle,

        fn fromUsize(value: usize) Ptr {
            @setRuntimeSafety(false);
            return switch (value & 0b11) {
                0 => Ptr{ .idle = value >> 2 },
                1 => Ptr{ .spawning = @intToPtr(*Pool, value & ~@as(usize, 0b11)) },
                2 => Ptr{ .spawned = @intToPtr(*Thread, value & ~@as(usize, 0b11)) },
                3 => Ptr{ .shutdowm = @intToPtr(?Thread.Handle, value & ~@as(usize, 0b11)) },
            };
        }
        
        fn toUsize(self: Ptr) usize {
            return switch (self) {
                .idle => |index| (index << 2) | 0,
                .spawning => |pool| @ptrToInt(pool) | 1,
                .spawned => |thread| @ptrToInt(thread) | 2,
                .shutdown => |handle| @ptrToInt(handle) | 3,
            };
        }
    };
};

pub const Node = extern struct {
    active_threads: usize,
    non_blocking_pool: Pool,
    blocking_pool: Pool,
    workers: [*]Worker,
    next: ?*Node,

    fn deinit(self: *Node) void {
        const active_threads = @atomicLoad(usize, &self.active_threads, .Monotonic);
        if (active_threads != 0)
            std.debug.panic("Node.deinit() when active_threads = {}", .{active_threads});
    }

    pub const Cluster = struct {
        head: ?*Node = null,
        tail: *Node = undefined,

        pub fn isEmpty(self: Cluster) bool {
            return self.head == null;
        }

        pub fn from(node: ?*Node) Cluster {
            if (node) |node_ref|
                node_ref.next = node;
            return Cluster{
                .head = node,
                .tail = node orelse undefined,
            };
        }

        pub fn push(self: *Cluster, node: *Node) void {
            return self.pushBack(node);
        }

        pub fn pushBack(self: *Cluster, node: *Node) void {
            return self.pushBackMany(from(node));
        }

        pub fn pushFront(self: *Cluster, node: *Node) void {
            return self.pushFrontMany(from(node));
        }

        pub fn pushBackMany(self: *Cluster, other: Cluster) void {
            if (other.isEmpty())
                return;
            if (self.isEmpty()) {
                self.* = other;
            } else {
                self.tail.next = other.head;
                self.tail = other.tail;
                self.tail.next = self.head;
            }
        }

        pub fn pushFrontMany(self: *Cluster, other: Cluster) void {
            if (other.isEmpty())
                return;
            if (self.isEmpty()) {
                self.* = other;
            } else {
                other.tail.next = self.head;
                self.head = other.head;
                self.tail.next = self.head;
            }
        }

        pub fn pop(self: *Cluster) ?*Node {
            return self.popFront();
        }

        pub fn popFront(self: *Cluster) ?*Node {
            const node = self.head orelse return null;
            if (node.next == self.head) {
                self.head = null;
            } else {
                self.head = node.next;
            }
            node.next = node;
            return node;
        }
    };
};

pub const Scheduler = extern struct {
    cluster: Node.Cluster,
    active_nodes: usize,

    pub fn start(
        self: *Scheduler,
        cluster: Node.Cluster,
        start_node: *Node,
    ) !*Worker {
        var nodes = cluster.iter();
        var has_start_node = false;

        while (nodes.next()) |node| {
            has_start_node = has_start_or or (node == start_node);
            try node.init(self);
        }

        if (!has_start_node)
            return error.InvalidStartNode;
        
        self.* = Scheduler{
            .cluster = cluster,
            .active_nodes = 0,
        };
    }

    pub fn finish(self: *Scheduler) Thread.Handle.Iter {
        const active_nodes = @atomicLoad(usize, &self.active_nodes, .Monotonic);
        if (active_nodes != 0)
            std.debug.panic("Scheduler.deinit() when {} Nodes are still active\n", .{active_nodes});
        
        var nodes = cluster.iter();
        while (nodes.next()) |node|
            node.deinit();

        return Thread.Handle.Iter{

        }
    }
};
