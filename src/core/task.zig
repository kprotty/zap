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

        pub fn schedule(self: Batch) void {
            if (self.isEmpty())
                return;
            const thread = Task.getCurrentThread();
            thread.schedule(self);
        }
    };

    pub const Thread = extern struct {
        runq_head: usize,
        runq_tail: usize,
        runq_next: ?*Task,
        runq_overflow: ?*Task,
        runq_buffer: [256]*Task,

        fn push(self: *Thread, tasks: Batch) void {
            var batch = tasks;

            {
                const task = batch.pop() orelse return;
                var runq_next = @atomicLoad(?*Task, &self.runq_next, .Monotonic);
                while (true) {

                    const old_next = runq_next orelse {
                        @atomicStore(?*Task, &self.runq_next, task, .Release);
                        break;
                    };

                    run_queue = @cmpxchgWeak(
                        ?*Task,
                        &self.runq_next,
                        old_next,
                        task,
                        .Release,
                        .Monotonic,
                    ) orelse {
                        batch.pushFront(old_next);
                        break;
                    };
                }
            }

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
                    .Monotonic,
                    .Monotonic,
                )) |updated_head| {
                    head = updated_head;
                    continue;
                }

                defer batch = Batch{};
                batch.pushFrontMany(blk: {
                    var overflowed = Batch{};
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

        fn pollLocal(self: *Thread) ?*Task {
            var runq_next = @atomicLoad(?*Task, &self.runq_next, .Monotonic);
            while (runq_next) |task| {
                runq_next = @cmpxchgWeak(
                    ?*Task,
                    &self.runq_next,
                    runq_next,
                    null,
                    .Monotonic,
                    .Monotonic,
                ) orelse return task;
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
                    .Monotonic,
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
                    .Monotonic,
                    .Monotonic,
                ) orelse {
                    self.inject(task.next);
                    return task;
                };
            }

            return null;
        }

        fn pollGlobal(noalias self: *Thread, noalias pool: *Pool) ?*Task {
            var run_queue = @atomicLoad(?*Task, &pool.run_queue, .Monotonic);
            while (run_queue) |task| {
                run_queue = @cmpxchgWeak(
                    ?*Task,
                    &pool.run_queue,
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

        fn pollSteal(noalias self: *Thread, noalias target: *Thread) ?*Task {
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
                    } else if (@atomicLoad(?*Task, &target.runq_next, .Monotonic)) |task| {
                        _ = @cmpxchgWeak(
                            ?*Task,
                            &target.runq_next,
                            task,
                            null,
                            .Acquire,
                            .Monotonic,
                        ) orelse return task;
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
        run_queue: ?*Task,
        idle_queue: usize,
        active_threads: usize,

        const IDLE_MARKED = 1;
        const IDLE_SHUTDOWN = ~@as(usize, 0);

        fn init(self: *Pool, worker_count: u32, is_blocking: bool) void {
            const num_workers = std.math.min(worker_count, ~@as(u32, 0) >> 1);
            self.* = Pool{
                .num_workers = (num_workers << 1) | @boolToInt(is_blocking),
                .run_queue = null,
                .idle_queue = 0,
                .active_threads = 0,
            };

            for (self.getWorkers()) |*worker, index| {
                const next_index = self.idle_queue >> 8;
                const idle_ptr = Worker.IdlePtr{ .worker = next_index };
                const worker_ptr = Worker.Ptr{ .idle = idle_ptr };
                worker.ptr = worker_ptr.toUsize();
                self.idle_queue = (index + 1) << 8;
            }
        }

        fn deinit(self: *Pool) void {
            const run_queue = @atomicLoad(?*Task, &self.run_queue, .Monotonic);
            if (run_queue != null)
                std.debug.panic("Pool.deinit() when run_queue is not empty", .{});

            const idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
            if (idle_queue != IDLE_SHUTDOWN)
                std.debug.panic("Pool.deinit() when idle_queue is not shutdown", .{});

            const active_threads = @atomicLoad(usize, &self.active_threads, .Monotonic);
            if (active_threads != 0)
                std.debug.panic("Pool.deinit() when active_threads = {}", .{active_threads});
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

        fn push(self: *Pool, batch: Batch) void {
            if (batch.isEmpty())
                return;

            var run_queue = @atomicLoad(?*Task, &self.run_queue, .Monotonic);
            while (true) {
                batch.tail.next = run_queue;
                run_queue = @cmpxchgWeak(
                    ?*Task,
                    &self.run_queue,
                    run_queue,
                    batch.head,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }
        }
    };

    pub const Worker = extern struct {
        ptr: usize,
    };

    pub const Node = extern struct {
        non_blocking_pool: Pool,
        blocking_pool: Pool,
        workers: [*]Worker,
    };

    pub const Scheduler = extern struct {
        cluster: Node.Cluster,
        active_pools: usize,

        pub fn start()

        pub fn run(
            task: *Task,
            cluster: Node.Cluster,
            start_node_index: u32,
        ) !void {
            var self = Scheduler{
                .active_pools = 0,
            };

            const start_node = blk: {
                var index: u32 = 0;
                var nodes = cluster.iter();
                var start_node: ?*Node = null;

                while (nodes.next()) |node| {
                    if (index == start_index)
                        start_node = node;
                    index += 1;
                    node.init(&self);
                }

                return start_node orelse error.InvalidStartIndex;
            };

            const pool = &start_node.non_blocking_pool;
            pool.push(Task.Batch.from(task));
            pool.resumeThread(.{ .is_main_thread = true });

            {
                const active_pools = @atomicLoad(usize, &self.active_pools, .Monotonic);
                if (active_pools != 0)
                    std.debug.panic("Scheduler.deinit() when {} pools are still active\n", .{active_pools});
                
                var nodes = cluster.iter();
                while (nodes.next()) |node|
                    node.deinit();
            }
        }
    };
};
