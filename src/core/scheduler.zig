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

const Atomic = zap.sync.Atomic;
const spinLoopHint = Atomic.spinLoopHint;

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

        pub fn iter(self: Batch) Task.Iter {
            return Task.Iter{ .current = self.head };
        }
    };

    pub const Iter = extern struct {
        current: ?*Task,

        pub fn isEmpty(self: Iter) bool {
            return self.current == null;
        }

        pub fn next(self: *Iter) ?*Task {
            const task = self.current orelse return null;
            self.current = task.next;
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
    node: *Node,
    next_index: usize,
    worker_index: usize,

    const IS_SUSPENDED = 1 << 0;
    const IS_WAKING = 1 << 1;
    const INDEX_SHIFT = 8;

    pub const Handle = extern struct {
        pub const Ptr = *const AlignedInt;
        pub const AlignedInt = std.meta.Int()

        fn from(token: usize) !Handle {
            if (std.mem.alignForward(token, 4) != token)
                error.Unaligned;
            return Handle{ .token = token };
        }

        pub const Iter = extern struct {
            node: *Node,
            index: usize = 0,

            pub fn next(self: *Iter) ?Handle {
                const workers = self.node.getWorkers();
                
                while (self.index < workers.len) : (self.index += 1) {
                    const worker_ptr = Atomic.load(&workers[self.index].ptr, .acquire);
                    switch (Worker.Ptr.fromUsize(worker_ptr)) {
                        .idle => std.debug.panic("Thread.Handle.Iter found idle worker {}", .{self.index}),
                        .idle => std.debug.panic("Thread.Handle.Iter found idle worker {}", .{self.index}),
                        @compileError("TODO"),
                    }
                }

                return null;
            }
        };
    };

    pub const Iter = extern struct {
        node: *Node,
        index: usize = 0,

        pub fn next(self: *Iter) ?*Thread {

        }
    };
    
    pub fn init(self: *Thread, worker: *Worker) void {
        var worker_ptr = Atomic.load(&worker.ptr, .acquire);
        const node = switch (Worker.Ptr.fromUsize(worker_ptr)) {
            .idle => std.debug.panic("Thread.init() when worker still idle", .{}),
            .spawning => |node| node,
            .spawned => std.debug.panic("Thread.init() when worker already has a thread", .{}),
            .shutdown => std.debug.panic("Thread.init() when worker is shutdown", .{}),
        };

        self.* = Thread{
            .local_head = &self.local_tail,
            .local_tail = Task{
                .next = null,
                .continuation = @ptrToInt(&self.local_tail),
            },
            .node = node,
            .next_index = THREAD_WAKING,
            .worker_index = toWorkerIndex(node.getWorkers(), worker),
        };

        worker_ptr = (Worker.Ptr{ .spawned = self }).toUsize();
        Atomic.store(&worker.ptr, worker_ptr, .release);
    }

    pub fn getNode(self: Thread) *Node {
        return self.node;
    }

    fn readBuffer(self: *const Thread, index: usize) *Task {
        const buffer_ptr = &self.runq_buffer[index % self.runq_buffer.len];
        return Atomic.load(buffer_ptr, .unordered);
    }

    fn writeBuffer(self: *Thread, index: usize, task: *Task) void {
        const buffer_ptr = &self.runq_buffer[index % self.runq_buffer.len];
        return Atomic.store(buffer_ptr, task, .unordered);
    }

    pub fn pushLocal(self: *Therad, batch: Task.Batch) void {
        if (batch.isEmpty())
            return;
        self.pushOnlyLocal(batch.head, batch.tail);
    }

    pub fn push(self: *Thread, tasks: Task.Batch) void {
        var batch = tasks;
        var tail = self.runq_tail;
        var head = Atomic.load(&self.runq_head, .relaxed);
        while (!batch.isEmpty()) {

            const size = tail -% head;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.push() with invalid runq size of {}", .{size});

            var remaining = self.runq_buffer.len - size;
            if (remaining != 0) {
                while (remaining != 0) : (remaining -= 1) {
                    const task = batch.pop() orelse break;
                    self.writeBuffer(tail);
                    tail +%= 1;
                }

                Atomic.store(&self.runq_tail, tail, .release);
                head = Atomic.load(&self.runq_head, .relaxed);
                continue;
            }

            const new_head = head +% (self.runq_buffer.len / 2);
            if (Atomic.compareAndSwap(
                .weak,
                &self.runq_head,
                head,
                new_head,
                .acquire,
                .relaxed,
            )) |updated_head| {
                head = updated_head;
                continue;
            }

            defer batch = Task.Batch{};
            batch.pushFrontMany(blk: {
                var overflowed = Task.Batch{};
                while (head != new_head) : (head +%= 1) {
                    overflowed.push(self.readBuffer(head));
                }
                break :blk overflowed;
            });

            var runq_overflow = Atomic.load(&self.runq_overflow, .relaxed);
            while (true) {
                batch.tail.next = runq_overflow;

                if (runq_overflow == null) {
                    Atomic.store(&self.runq_overflow, batch.head, .release);
                    break;
                }

                runq_overflow = Atomic.compareAndSwap(
                    .weak,
                    &self.runq_overflow,
                    runq_overflow,
                    batch.head,
                    .release,
                    .relaxed,
                ) orelse break;
            }
        }
    }

    fn inject(self: *Thread, run_queue: ?*Task) void {
        var runq = Task.Iter{ .current = runq_queue orelse return };
        var tail = self.runq_tail;
        var head = Atomic.load(&self.runq_head, .relaxed);

        const size = tail -% head;
        if (size > self.runq_buffer.len)
            std.debug.panic("Thread.inject() with invalid runq size of {}", .{size});
        if (size != 0)
            std.debug.panic("Thread.inject() when not empty with runq size of {}", .{size});

        var remaining: usize = self.runq_buffer.len;
        while (remaining != 0) : (remaining -= 1) {
            const task = runq.next() orelse break;
            self.writeBuffer(tail, task);
            tail +%= 1;
        }

        Atomic.store(&self.runq_tail, tail, .release);
        if (runq.isEmpty())
            return;

        const runq_overflow = Atomic.load(&self.runq_overflow, .relaxed);
        if (runq_overflow != null) {
            std.debug.panic("Thread.inject() when runq overflow is not empty", .{});
        } else {
            Atomic.store(&self.runq_overflow, runq, .release);
        }
    }

    fn pushOnlyLocal(self: *Thread, head: ?*Task, tail: *Task) void {
        const prev = Atomic.update(&self.local_head, .swap, tail, .acq_rel);
        Atomic.store(&prev.next, head, .release);
    }

    fn pollOnlyLocal(self: *Thread) ?*Task {
        @setRuntimeSafety(false);
        const stub_ptr = &self.local_runq;
        const tail_ptr = @ptrCast(**Task, &self.local_runq.continuation);
        
        var tail = tail_ptr.*;
        var next = Atomic.load(&tail.next, .acquire);

        if (tail == stub_ptr) {
            tail = next orelse break :blk;
            tail_ptr.* = tail;
            next = Atomic.load(&tail.next, .acquire);
        }

        if (next) |new_tail| {
            tail_ptr.* = new_tail;
            return tail;
        }

        var wait_on_push: u4 = 8;
        while (true) {
            const head = Atomic.load(&self.local_head, .relaxed);
            if (tail == head)
                break;
            if (wait_on_push == 0)
                return null;
            wait_on_push -= 1;
            spinLoopHint();
        }

        stub_ptr.next = null;
        self.pushOnlyLocal(stub_ptr, stub_ptr);

        next = Atomic.load(&tail.next, .acquire);
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
        var head = Atomic.load(&self.runq_head, .relaxed);
        while (true) {

            const size = tail -% head;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.pollLocal() with invalid runq size of {}", .{size});
            if (size == 0)
                break;

            head = Atomic.compareAndSwap(
                .weak,
                &self.runq_head,
                head,
                head +% 1,
                .acquire,
                .relaxed,
            ) orelse return self.readBuffer(head);
        }

        var runq_overflow = Atomic.load(&self.runq_overflow, .relaxed);
        while (runq_overflow) |task| {
            runq_overflow = Atomic.compareAndSwap(
                .weak,
                &self.runq_overflow,
                task,
                null,
                .acquire,
                .relaxed,
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

    fn pollOnlyGlobal(noalias self: *Thread, noalias run_queue_ptr: *?*Task) ?*Task {
        var run_queue = Atomic.load(run_queue_ptr, .relaxed);
        while (true) {
            const task = run_queue orelse return null;
            run_queue = Atomic.compareAndSwap(
                .weak,
                run_queue_ptr,
                run_queue,
                null,
                .acquire,
                .relaxed,
            ) orelse {
                self.inject(task.next);
                return task;
            };
        }
    }

    pub fn pollGlobal(noalias self: *Thread, noalias node: *Node) ?*Task {
        if (node == self.getNode()) {
            if (self.pollOnlyGlobal(&node.local_runq)) |task|
                return task;
        }

        if (self.pollOnlyGlobal(&node.shared_runq)) |task| {
            return task;
        }

        return null;
    }

    pub fn pollSteal(noalias self: *Thread, noalias target: *Thread) ?*Task {
        var tail = self.runq_tail;
        var head = Atomic.load(&self.runq_head, .relaxed);

        const size = tail -% head;
        if (size > self.runq_buffer.len)
            std.debug.panic("Thread.pollSteal() with invalid runq of size {}", .{size});
        if (size != 0)
            std.debug.panic("Thread.pollSteal() when runq not empty with size of {}", .{size});

        var target_head = Atomic.load(&target.runq_head, .relaxed);
        while (true) {
            const target_tail = Atomic.load(&target.runq_tail, .acquire);

            const target_size = target_tail -% target_head;
            if (target_size > self.runq_buffer.len) {
                spinLoopHint();
                target_head = Atomic.load(&target.runq_head, .relaxed);
                continue;
            }

            var steal = target_size - (target_size / 2);
            if (steal == 0) {
                if (Atomic.load(&target.runq_overflow, .relaxed)) |task| {
                    _ = Atomic.compareAndSwap(
                        .weak,
                        &target.runq_overflow,
                        task,
                        null,
                        .acquire,
                        .relaxed,
                    ) orelse {
                        self.inject(task.next);
                        return task;
                    };
                } else {
                    break;
                }

                spinLoopHint();
                target_head = Atomic.load(&target.runq_head, .relaxed);
                continue;
            }

            var new_tail = tail;
            var new_target_head = target_head;
            var first_task: ?*Task = null;

            while (steal != 0) : (steal -= 1) {
                const task = target.readBuffer(new_target_head);
                new_target_head +%= 1;

                if (first_task == null) {
                    first_task = task;
                } else {
                    self.writeBuffer(new_tail, task);
                    new_tail +%= 1;
                }
            }

            if (Atomic.compareAndSwap(
                .weak,
                &target.runq_head,
                target_head,
                new_target_head,
                .acquire,
                .relaxed,
            )) |updated_target_head| {
                target_head = updated_target_head;
                continue;
            }

            if (new_tail != tail)
                Atomic.store(&self.runq_tail, new_tail, .release);
            return first_task;
        }

        return null;
    }
};

pub const Worker = extern struct {
    ptr: usize,

    pub const alignment = Ptr.MASK + 1;

    const Ptr = union(enum) {
        idle: u32,
        spawning: *Node,
        spawned: *Thread,
        shutdown: ?Thread.Handle.Ptr,

        const MASK = 0b11;

        fn fromUsize(value: usize) Ptr {
            @setRuntimeSafety(false);
            return switch (value & MASK) {
                0 => Ptr{ .idle = value >> @popCount(u2, MASK) },
                1 => Ptr{ .spawning = @intToPtr(*Node, value & ~@as(usize, MASK)) },
                2 => Ptr{ .spawned = @intToPtr(*Thread, value & ~@as(usize, MASK)) },
                3 => Ptr{ .shutdowm = @intToPtr(?Thread.Handle.Ptr, value & ~@as(usize, MASK)) },
            };
        }
        
        fn toUsize(self: Ptr) usize {
            return switch (self) {
                .idle => |index| (index << @popCount(u2, MASK)) | 0,
                .spawning => |node| @ptrToInt(node) | 1,
                .spawned => |thread| @ptrToInt(thread) | 2,
                .shutdown => |handle| @ptrToInt(handle) | 3,
            };
        }
    };
};

pub const Node = extern struct {
    next: ?*Node,
    scheduler: *Scheduler,
    workers_ptr: [*]Worker,
    workers_len: u32,
    local_runq: ?*Task,
    shared_runq: ?*Task,
    idle_queue: usize,
    active_threads: usize,

    const IDLE_MARKED = 1;
    const IDLE_SHUTDOWN = ~@as(usize, 0);
    const MAX_WORKERS = (std.math.maxInt(u32) >> 8) - 1;

    pub fn setup(self: *Node, workers: []Worker) !void {
        self.next = self;
        self.workers_ptr = workers.ptr;
        self.workers_len = @intCast(u32, std.math.min(workers.len, MAX_WORKERS));
    }

    fn init(self: *Node, scheduler: *Scheduler) void {
        self.scheduler = scheduler;
        self.local_runq = null;
        self.shared_runq = null;
        self.idle_queue = blk: {
            const workers = self.getWorkers();
            for (workers) |*worker, index|
                worker.ptr = (Worker.Ptr{ .idle = index }).toUsize();
            break :blk ((workers.len + 1) << 8);
        };
    }

    fn deinit(self: *Node) void {
        const active_threads = Atomic.load(&self.active_threads, .relaxed);
        if (active_threads != 0)
            std.debug.panic("Node.deinit() when active_threads = {}", .{active_threads});

        const local_runq = Atomic.load(&self.local_runq, .relaxed);
        if (local_runq != null)
            std.debug.panic("Node.deinit() when local_runq is not empty", .{});

        const shared_runq = Atomic.load(&self.shared_runq, .relaxed);
        if (shared_runq != null)
            std.debug.panic("Node.deinit() when shared_runq is not empty", .{});

        const idle_queue = Atomic.load(&self.idle_queue, .relaxed);
        if (idle_queue != IDLE_SHUTDOWN)
            std.debug.panic("Node.deinit() when idle_queue is not shutdown", .{});
    }

    pub const Iter = extern struct {
        start: *Node,
        current: ?*Node,

        pub fn isEmpty(self: Iter) bool {
            return self.current == null;
        }

        pub fn next(self: *Iter) ?*Node {
            const node = self.current orelse return null;
            self.current = node.next;
            if (self.current == self.start)
                self.current = null;
            return node;
        }
    };

    pub fn iter(self: *Node) Iter {
        return Iter{
            .start = self,
            .current = self,
        };
    }

    pub fn getScheduler(self: Node) *Scheduler {
        return self.scheduler;
    }

    pub fn getWorkers(self: *Node) []Worker {
        return self.workers_ptr[0..self.workers_len];
    }

    fn toWorkerIndex(workers: []Worker, worker: *Worker) usize {
        const ptr = @ptrToInt(worker);
        const base = @ptrToInt(workers.ptr);
        const end = base + (workers.len * @sizeOf(Worker));

        if (ptr < base or ptr >= end)
            std.debug.panic("Node.toWorkerIndex() with invalid worker\n", .{});

        return (ptr - base) / @sizeOf(Worker);
    }

    pub fn push(self: *Node, batch: Task.Batch) void {
        return self.pushBatch(&self.shared_runq, batch);
    }

    pub fn pushLocal(self: *Node, batch: Task.Batch) void {
        return self.pushBatch(&self.local_runq, batch);
    }

    fn pushBatch(run_queue_ptr: *?*Task, batch: Task.Batch) void {
        if (batch.isEmpty())
            return;

        var run_queue = Atomic.load(run_queue_ptr, .relaxed);
        while (true) {
            batch.tail.next = run_queue;
            run_queue = Atomic.compareAndSwap(
                .weak
                run_queue_ptr,
                run_queue,
                batch.head,
                .release,
                .relaxed,
            ) orelse break;
        }
    }

    pub const Schedule = struct {
        node: usize,
        ptr: usize,

        pub const Result = union(enum) {
            notified: void,
            spawned: *Worker,
            resumed: *Thread,
        };

        fn from(
            node: *Node,
            result: Result,
            first_in_node: bool,
            first_in_scheduler: bool,
        ) Schedule {
            return Schedule{
                .node = @ptrToInt(node)
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
            return (self.node & (1 << 1)) != 0;
        }

        pub fn wasFirstInScheduler(self: Schedule) bool {
            return (self.node & (1 << 0)) != 0;
        }

        pub fn getNode(self: Schedule) *Node {
            @setRuntimeSafety(false);
            return @intToPtr(*Node, self.node & ~@as(usize, 0b11)); 
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
            return self.getNode().undoResumeThread(self.getResult());
        }
    };

    pub fn tryResumeThread(self: *Node) ?Schedule {
        return self.resumeThread(.{ .check_remote = true });
    }

    pub fn tryResumeLocalThread(self: *Node) ?Schedule {
        return self.resumeThread(.{});
    }

    const ResumeOptions = struct {
        was_waking: bool = false,
        check_remote: bool = false,
    };

    fn resumeThread(self: *Node, options: ResumeOptions) ?Schedule {
        const workers = self.getWorkers();
        var idle_queue = Atomic.load(&self.idle_queue, .acquire);

        while (true) {
            if (idle_queue == IDLE_SHUTDOWN)
                std.debug.panic("Node.resumeThread() when already shutdown", .{});

            var worker_index = idle_queue >> 8;
            var new_result: Schedule.Result = undefined;
            var new_idle_queue = idle_queue & (~@as(u8, 0) << 1);

            if (worker_index != 0) {
                if (!options.was_waking and (idle_queue & IDLE_MARKED != 0))
                    break;

                worker_index -= 1;
                const worker = &workers[worker_index];
                const ptr = Atomic.load(&worker.ptr, .acquire);

                switch (Worker.Ptr.fromUsize(ptr)) {
                    .idle => |next_index| {
                        new_result = Schedule.Result{ .spawned = worker };
                        new_idle_queue = (next_index << 8) | @boolToInt(next_index != 0);
                    },
                    .spawning => {
                        spinLoopHint();
                        idle_queue = Atomic.load(&self.idle_queue, .acquire);
                        continue;
                    },
                    .spawned => |thread| {
                        const next_index = Atomic.load(&thread.next_index, .unordered) >> Thread.INDEX_SHIFT;
                        new_result = Schedule.Result{ .resumed = thread };
                        new_idle_queue = next_index | @boolToInt(next_index != 0);
                    },
                    .shutdown => {
                        std.debug.panic("Node.resumeThread() when worker {} already shutdown", .{worker_index});
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

            switch (new_result) {
                .notified => {
                    return Schedule.from(self, new_result, false, false);
                },
                .spawned => |worker| {
                    const worker_ptr = (Worker.Ptr{ .spawning = node }).toUsize();
                    Atomic.store(&worker.ptr, worker_ptr, .release);
                },
                .resumed => |thread| {
                    const next_index = Atomic.load(&thread.next_index, .unordered);
                    if (next_index & Thread.IS_SUSPENDED != 0) {
                        Atomic.store(&thread.next_index, Thread.IS_WAKING, .unordered);
                    } else {
                        spinLoopHint();
                        idle_queue = Atomic.load(&self.idle_queue, .acquire);
                        continue;
                    }  
                },
            }

            const first_in_node = blk: {
                const active_threads = Atomic.update(&self.active_threads, .add, 1, .relaxed);
                break :blk (active_threads == 0);
            };
            const first_in_scheduler = first_in_node and blk: {
                const scheduler = self.getScheduler();
                const active_nodes = Atomic.update(&scheduler.active_nodes, .add, 1, .relaxed);
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
            var nodes = self.iter();
            _ = nodes.next();
            while (nodes.next()) |remote_node| {
                if (remote_node.tryResumeLocalThread()) |schedule| {
                    return scheudle;
                }
            }
        }

        return null;
    }

    fn undoResumeThread(self: *Node, result: Schedule.Result) void {
        switch (result) {
            .notified => return,
            .spawned, .resumed => {
                if (Atomic.update(&self.active_threads, .sub, 1, .relaxed) == 0) {
                    const scheduler = self.getScheduler();
                    _ = Atomic.update(&scheduler.active_nodes, .sub, 1, .relaxed);
                }
            },
        }

        const workers = self.getWorkers();
        var idle_queue = Atomic.load(&self.idle_queue, .relaxed);

        while (true) {
            if (idle_queue == IDLE_SHUTDOWN)
                std.debug.panic("Node.undoResumeThread() when already shutdown", .{});
            if (idle_queue & IDLE_MARKED == 0)
                std.debug.panic("Node.undoResumeThread() when not waking", .{});

            var next_index = idle_queue >> 8;
            var aba_tag = @truncate(u7, idle_queue >> 1);

            next_index = switch (result) {
                .notified => unreachable,
                .spawned => |worker| blk: {
                    const worker_ptr = Worker.Ptr{ .idle = next_index };
                    Atomic.store(&worker.ptr, worker_ptr.toUsize(), .relaxed);
                    break :blk toWorkerIndex(workers, worker);
                },
                .resumed => |thread| blk: {
                    const index = Atomic.load(&thread.next_index, .unordered);
                    if (index & Thread.IS_SUSPENDED != 0)
                        std.debug.panic("Node.undoResumeThread() when thread still suspended", .{});
                    if (index & Thread.IS_WAKING == 0)
                        std.debug.panic("Node.undoResumeThread() when thread is not waking", .{});

                    next_index = (next_index << Thread.INDEX_SHIFT) | Thread.IS_SUSPENDED;
                    Atomic.store(&thread.next_index, next_index, .unordered);
                    break :blk thread.worker_index;
                },
            };

            idle_queue = Atomic.compareAndSwap(
                .weak,
                &self.idle_queue,
                idle_queue,
                @as(usize, aba_tag +% 1) | (next_index << 8),
                .release,
                .relaxed,
            ) orelse break;
        }
    }

    pub const Suspend = union(enum) {
        idle: void,
        notified: void,
        suspended: Result,

        pub const Result = struct {
            last_in_node: bool,
            last_in_scheduler: bool,
        };
    };

    pub fn suspendThread(noalias self: *Node, noalias thread: *Thread) Suspended {
        const workers = self.getWorkers();
        const worker_index = thread.worker_index + 1;
        const worker = &workers[worker_index - 1];

        var next_index = Atomic.load(&thread.next_index, .unordered);
        const is_waking = next_index & Thread.IS_WAKING != 0;
        if (next_index & Thread.IS_SUSPENDED != 0)
            return Suspended{ .idle = {} };

        var idle_queue = Atomic.load(&self.idle_queue, .relaxed);
        while (true) {
            if (idle_queue == IDLE_SHUTDOWN)
                std.debug.panic("Node.suspendThread() when already shutdown", .{});

            next_index = idle_queue >> 8;
            const aba_tag = @truncate(u7, idle_queue >> 1);
            var new_idle_queue = (worker_index << 8) | (idle_queue & IDLE_MARKED);

            const notified = (next_index == 0) and (idle_queue & IDLE_MARKED != 0);
            if (notified) {
                new_idle_queue = @as(usize, aba_tag) << 1;
            } else {
                new_idle_queue |= @as(usize, aba_tag +% 1) << 1;
                if (is_waking)
                    new_idle_queue &= ~@as(usize, IDLE_MARKED);
                next_index = (next_index << Thread.INDEX_SHIFT) | Thread.IS_SUSPENDED;
                Atomic.store(&thread.next_index, next_index, .unordered);
            }

            if (Atomic.compareAndSwap(
                .weak,
                &self.idle_queue,
                idle_queue,
                new_idle_queue,
                .acq_rel,
                .relaxed,
            )) |updated_idle_queue| {
                idle_queue = updated_idle_queue;
                continue;
            }

            if (notified) {
                next_index = if (is_waking) Thread.IS_WAKING else 0;
                Atomic.store(&thread.next_index, next_index, .unordered);
                return Suspend{ .notified = {} };
            }

            const last_in_node = blk: {
                const active_threads = Atomic.update(&self.active_threads, .sub, 1, .relaxed);
                break :blk (active_threads == 1);
            };
            const last_in_scheduler = last_in_node and blk: {
                const scheduler = self.getScheduler();
                const active_nodes = Atomic.update(&scheduler.active_nodes, .sub, 1, .relaxed);
                break :blk (active_nodes == 1);
            };

            return Suspended{
                .suspended = .{
                    .last_in_node = last_in_node,
                    .last_in_scheduler = last_in_scheduler,
                },
            };
        }
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

        pub fn iter(self: Cluster) Node.Iter {
            return Node.Iter{
                .start = self.head orelse undefined,
                .current = self.head,
            };
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
            has_start_node = has_start_node or (node == start_node);
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
        const active_nodes = Atomic.load(&self.active_nodes, .relaxed);
        if (active_nodes != 0)
            std.debug.panic("Scheduler.deinit() when {} Nodes are still active\n", .{active_nodes});
        
        var nodes = cluster.iter();
        while (nodes.next()) |node|
            node.deinit();

        return Thread.Handle.Iter{

        }
    }
};
