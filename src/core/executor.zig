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
const zap = @import("../zap.zig");

pub fn Executor(comptime Platform: type) type {
    return struct {
        const cache_align = 
            if (@hasDecl(Platform, "cache_align")) Platform.cache_align
            else DefaultPlatform.cache_align;

        const task_buffer_size = 
            if (@hasDecl(Platform, "task_buffer_size")) Platform.task_buffer_size
            else DefaultPlatform.task_buffer_size;

        const is_debug =
            if (@hasDecl(Platform, "is_debug")) Platform.is_debug
            else DefaultPlatform.is_debug;

        const panic =
            if (@hasDecl(Platform, "panic")) Platform.panic
            else DefaultPlatform.panic;

        const AtomicUsize =
            if (@hasDecl(Platform, "AtomicUsize")) Platform.AtomicUsize
            else DefaultPlatform.AtomicUsize;

        const Event =
            if (@hasDecl(Platform, "Event")) Platform.Event
            else DefaultPlatform.Event;

        const ThreadLocal =
            if (@hasDecl(Platform, "ThreadLocal")) Platform.ThreadLocal
            else DefaultPlatform.ThreadLocal;

        pub const Task = extern struct {
            next: ?*Task = undefined,
            continuation: usize,

            pub fn init(frame: anyframe) Task {
                if (@alignOf(anyframe) < 2)
                    @compileError("anyframe has unsupported alignment");
                return Task{ .continuation = @ptrToInt(frame) };
            }

            pub const Callback = fn(
                noalias *Task,
                noalias *Thread,
            ) callconv(.C) CallbackReturn;

            pub const CallbackReturn = void;

            pub fn initFn(callback: Callback) Task {
                if (@alignOf(Callback) < 2)
                    @compileError("Callback function pointer has unsupported alignment");
                return Task{ .continuation = @ptrToInt(frame) | 1 };
            }

            pub fn execute(self: *Task, thread: *Thread) void {
                switch (self.continuation & 1) {
                    0 => resume (blk: {
                        @setRuntimeSafety(false);
                        break :blk @intToPtr(anyframe, self.continuation);
                    }),
                    1 => (blk: {
                        @setRuntimeSafety(false);
                        break :blk @intToPtr(Callback, self.continuation & ~@as(usize, 1));
                    })(self, thread),
                    else => unreachable,
                }
            }

            pub inline fn getCurrentThread() *Thread {
                return Thread.getCurrent();
            }

            pub fn yieldAsync() void {
                suspend {
                    var task = Task.init(@frame());
                    task.yield(getCurrentThread());
                }
            }

            pub fn yield(self: *Task, thread: *Thread) CallbackReturn {
                const next_task = thread.poll() orelse self;
                thread.schedule(next_task.toBatch(), .next);
                
                if (next_task != self) {
                    thread.schedule(self.toBatch(), .shared);
                }
            }

            pub fn toBatch(self: *Task) Batch {
                return Batch.from(self);
            }

            pub const Batch = extern struct {
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

                pub fn iter(self: Batch) Iter {
                    return Iter{ .current = self.head };
                }

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
        };        

        pub const Thread = extern struct {
            runq_overflow: AtomicUsize = AtomicUsize.init(0),
            runq_local: AtomicUsize = AtomicUsize.init(0),
            runq_next: AtomicUsize = AtomicUsize.init(0),
            runq_head: AtomicUsize = AtomicUsize.init(0),
            runq_tail: AtomicUsize align(cache_line) = AtomicUsize.init(0),
            runq_buffer: [task_buffer_size]AtomicUsize align(cache_line) = undefined,
            runq_owned: ?*Task = null,
            ptr: AtomicUsize,
            xorshift: usize,
            event: Event,

            const IS_SHUTDOWN = 0;
            const IS_WAKING = 1 << 0;
            const DID_INJECT = 1 << 1;
            const IS_SUSPENDED = 1 << 2;

            pub const Handle = *const u32;

            var tls_current: ThreadLocal = ThreadLocal{};

            pub fn getCurrent() *Thread {
                const ptr = tls_current.get();
                if (ptr == 0) {
                    panic("Thread.getCurrent() called when not running inside an Executor thread", .{});
                }

                @setRuntimeSafety(false);
                return @intToPtr(*Thread, ptr);
            }

            pub fn run(handle: ?Handle, worker: *Worker) void {
                var worker_ptr = worker.ptr.loadAcquire();
                const node = switch (Worker.Ptr.fromUsize(worker_ptr))  {
                    .idle => panic("Thread.run() started with worker that is still idle", .{}),
                    .spawning => |node| node,
                    .running => panic("Thread.run() started with worker already associated with another thread", .{}),
                    .shutdown => panic("Thread.run() started with worker already shutdown", .{}),
                };

                var self = Thread{
                    .node_ptr = AtomicUsize.init(@ptrToInt(node) | IS_WAKING),
                    .xorshift = @ptrToInt(worker) * 31,
                    .event = undefined,
                };

                self.event.init();
                defer self.event.deinit();

                worker_ptr = Worker.Ptr{ .running = &self };
                worker.ptr.storeRelease(worker_ptr.toUsize());

                const old_current = tls_current.get();
                tls_current.set(@ptrToInt(&self));
                defer tls_current.set(old_current);

                while (!self.isShutdown()) {
                    if (self.poll()) |task| {
                        task.execute(self);
                    } else {
                        self.wait();
                    }
                }
            }

            pub fn getNode(self: Thread) *Node {
                const alignment = (IS_WAKING | IS_SUSPENDED | DID_INJECT) + 1;
                if (@alignOf(Node) < alignment)
                    @compileError("Node alignment unsupported");

                const ptr = self.ptr.get();
                if (is_debug and (ptr & IS_SUSPENDED != 0))
                    panic("Thread.getNode() when suspended", .{});

                @setRuntimeSafety(false);
                return @intToPtr(*Node, ptr & ~@as(usize, 0b11));
            }

            fn isShutdown(self: Thread) bool {
                return self.ptr.get() == IS_SHUTDOWN;
            }

            fn shutdown(self: *Thread) void {
                self.ptr.set(IS_SHUTDOWN);
            }

            fn poll(self: *Thread) ?*Task {
                const task = self.findTask() orelse return null;

                const is_waking = self.node_ptr & IS_WAKING != 0;
                const did_inject = self.node_ptr & DID_INJECT != 0;
                self.node_ptr &= ~@as(usize, IS_WAKING | DID_INJECT);

                if (is_waking or did_inject) {
                    const node = self.getNode();
                    node.resumeThread(.{ .was_waking = is_waking });
                }

                return task;
            }

            fn findTask(self: *Thread) ?*Task {
                if (self.pop()) |task| {
                    return task;
                }

                var steal_attempts: u8 = 2;
                while (steal_attempts != 0) : (steal_attempts -= 1) {
                    const is_desperate = steal_attempts < 2;

                    switch (std.meta.bitCount(usize)) {
                        8 => {
                            self.xorshift ^= self.xorshift << 13;
                            self.xorshift ^= self.xorshift >> 7;
                            self.xorshift ^= self.xorshift << 17;
                        },
                        4 => {
                            self.xorshift ^= self.xorshift << 13;
                            self.xorshift ^= self.xorshift >> 17;
                            self.xorshift ^= self.xorshift << 5;
                        },
                        else => {
                            @compileError("Xorshift: architecture not supported");
                        },
                    }

                    var nodes = self.getNode().iter();
                    while (nodes.next()) |node| {
                        const num_workers = node.workers_len;

                        var index = self.xorshift % num_workers;
                        var iter = num_workers;
                        while (iter != 0) : (iter -= 1) {
                            const worker_index = index;
                            index = if (index == num_workers - 1) 0 else (index + 1);

                            const worker = &node.workers_ptr[worker_index];
                            const worker_ptr = worker.ptr.loadAcquire();
                            switch (Worker.Ptr.fromUsize(worker_ptr)) {
                                .idle => {},
                                .spawning => {},
                                .thread => |thread| {
                                    if (self.steal(Target{ .shared = thread }, is_desperate)) |task| {
                                        return task;
                                    }
                                },
                                .shutdown => {
                                    panic("Thread.findTask() found worker {} already shutdown", .{worker_index});
                                },
                            }
                        }

                        if (self.steal(Target{ .global = node })) |task| {
                            return task;
                        }
                    }
                }

                return null;
            }

            pub const Affinity = enum {
                next,
                local,
                shared,
            };

            pub fn schedule(self: *Thread, batch: Task.Batch, affinity: Affinity) void {
                if (batch.isEmpty())
                    return;

                self.push(batch, affinity);
                
                switch (affinity) {
                    .next => {},
                    .local => self.notify(),
                    .shared => self.getNode().resumeThread(.{}),
                }
            }

            fn push(self: *Thread, batch: Task.Batch, affinity: Affinity) void {
                if (batch.isEmpty())
                    return;

                switch (affinity) {
                    .next => self.pushOwned(batch),
                    .local => self.pushLocal(batch),
                    .shared => self.pushShared(batch),
                }
            }

            fn pushOwned(self: *Thread, batch: Task.Batch) void {
                batch.tail.next = self.runq_owned;
                self.runq_owned = batch.head;
            }

            fn pushLocal(self: *Thread, batch: Task.Batch) void {
                var runq_local = self.runq_local.load();
                while (true) {
                    batch.tail.next = @intToPtr(?*Task, runq_local);
                    runq_local = self.runq_local.compareAndSwapRelease(
                        runq_local,
                        @ptrToInt(batch.head),
                    ) orelse break;
                }
            }

            fn pushShared(self: *Thread, batch: Task.Batch) void {
                var tasks = batch;
                var tail = self.runq_tail.get();
                var head = self.runq_head.load();

                while (!tasks.isEmpty()) {
                    if (self.runq_next.load() == 0) {
                        self.runq_next.storeRelease(@ptrToInt(tasks.pop()));
                        continue;
                    }

                    const runq_size = tail -% head;
                    if (is_debug) {
                        if (runq_size > self.runq_buffer.len)
                            panic("Thread.pushShared() observed invalid runq buffer size of {}", .{runq_size});
                    }

                    var remaining = self.runq_buffer - runq_size;
                    if (remaining > 0) {
                        while (remaining != 0) : (remaining -= 1) {
                            const task = tasks.pop() orelse break;
                            self.writeBuffer(tail, task);
                            tail +%= 1;
                        }

                        self.runq_tail.storeRelease(tail);
                        head = self.runq_head.load();
                        continue;
                    }

                    const new_head = head +% (self.runq_buffer.len / 2);
                    if (self.runq_head.compareAndSwapAcquire(
                        head,
                        new_head,
                    )) |updated_head| {
                        head = updated_head;
                        continue;
                    }

                    tasks.pushFrontMany(blk: {
                        var overflowed = Task.Batch{};
                        while (head != new_head) : (head +%= 1) {
                            const old_task = self.readBuffer(head);
                            overflowed.pushBack(old_task);
                        }
                        break :blk overflowed;
                    });

                    var runq_overflow = self.runq_overflow.load();
                    while (true) {
                        tasks.tail.next = @intToPtr(?*Task, runq_overflow);
                        const new_runq_overflow = @ptrToInt(tasks.head);

                        if (runq_overflow == 0) {
                            self.runq_overflow.storeRelease(new_runq_overflow);
                            break;
                        }

                        runq_overflow = self.runq_overflow.compareAndSwapRelease(
                            runq_overflow,
                            new_runq_overflow,
                        ) orelse break;
                    }

                    return;
                }                
            }

            fn pop(self: *Thread) ?*Task {
                if (self.popLocal()) |task| {
                    return task;
                }

                if (self.popShared()) |task| {
                    return task;
                }

                if (self.popOverflow()) |task| {
                    return task;
                }
            }

            fn popLocal(self: *Thread) ?*Task {
                while (true) {
                    if (self.runq_owned) |runq_owned| {
                        const task = runq_owned;
                        self.runq_owned = task.next;
                        return task;
                    }

                    if (self.runq_local.load() != 0) {
                        const runq_local = self.runq_local.swapAcquire(0);
                        self.runq_owned = @intToPtr(?*Task, runq_local);
                        continue;
                    }

                    return null;
                }
            }

            fn popShared(self: *Thread) ?*Task {
                const tail = self.runq_tail.get();
                var head = self.runq_head.load();

                while (true) {
                    if (tail == head)
                        break;
                    head = self.runq_head.compareAndSwap(
                        head,
                        head +% 1,
                    ) orelse return self.readBuffer(head);
                }

                return null;
            }

            fn popOverflow(self: *Thread) ?*Task {
                var runq_overflow = self.runq_overflow.load();

                while (@intToPtr(?*Task, runq_overflow)) |task| {
                    runq_overflow = self.runq_overflow.compareAndSwap(
                        runq_overflow,
                        0,
                    ) orelse {
                        self.inject(task.next);
                        return task;
                    };
                }

                return null;
            }

            const Target = union(enum) {
                shared: *Thread,
                global: *Node,
            };

            fn steal(self: *Thread, target: Target, is_desperate: bool) ?*Task {
                switch (target) {
                    .shared => |thread| {
                        if (self == thread)
                            return null;
                        return self.stealShared(thread, is_desperate);
                    },
                    .global => |node| {
                        if (node == self.getNode()) {
                            if (self.stealGlobal(&node.runq_local)) |task| {
                                return task;
                            }
                        }
                        return self.stealGlobal(&node.runq_shared);
                    },
                }
            }

            fn stealGlobal(noalias self: *Thread, noalias run_queue_ptr: *AtomicUsize) ?*Task {
                var run_queue = run_queue_ptr.load();

                while (@intToPtr(?*Task, run_queue)) |task| {
                    run_queue = run_queue.ptr.compareAndSwapAcquire(
                        run_queue,
                        0,
                    ) orelse {
                        self.inject(task.next);
                        return task;
                    };
                }

                return null;
            }

            fn stealShared(noalias self: *Thread, noalias target: *Thread, is_desperate: bool) ?*Task {
                const tail = self.runq_tail.get();
                if (is_debug) {
                    const head = self.runq_head.load();
                    if (tail != head)
                        panic("Thread.stealShared() when runq buffer not empty with size of {}", .{tail -% head});
                }

                var target_head = target.runq_head.load();
                while (true) {
                    const target_tail = target.runq_tail.loadAcquire();
                    const target_size = target_tail -% target_head;
                    
                    var steal = target_size - (target_size / 2);

                    if (steal == 0) {
                        if (target.runq_overflow.load() != 0) {
                            const target_overflow = target.runq_overflow.swapAcquire(0);
                            if (@intToPtr(?*Task, target_overflow)) |task| {
                                self.inject(task.next);
                                return task;
                            }
                        }

                        if (is_desperate and target.runq_next.load() != 0) {
                            const target_next = target.runq_next.swapAcquire(0);
                            if (@intToPtr(?*Task, target_next)) |task| {
                                return task;
                            }
                        }

                        break;

                    } else if (steal < target.runq_buffer.len / 2) {
                        const task = target.readBuffer(new_target_head);
                        var new_target_head = target_head +% 1;
                        var new_tail = tail;
                        steal -= 1;

                        while (steal != 0) : (steal -= 1) {
                            const new_task = target.readBuffer(new_target_head);
                            new_target_head +%= 1;
                            self.writeBuffer(new_tail, new_task);
                            new_tail +%= 1;
                        }

                        if (target.head.compareAndSwapAcquireRelease(
                            target_head,
                            new_target_head,
                        )) |updated_target_head| {
                            target_head = updated_target_head;
                            continue;
                        }

                        self.node_ptr |= DID_INJECT;
                        if (new_tail != tail)
                            self.runq_tail.storeRelease(new_tail);
                        return task;
                    }

                    self.event.yield();
                    target_head = target.head.load();
                    continue;
                }

                return null;
            }

            fn inject(self: *Thread, stack: ?*Task) void {
                var runq = stack orelse return;

                var tail = self.runq_tail.get();
                if (is_debug) {
                    const head = self.runq_head.load();
                    if (tail != head)
                        panic("Thread.inject() with non empty runq buffer of size: {}", .{tail -% head});
                }

                const max_tail = tail +% self.runq_buffer.len;
                while (tail != max_tail) {
                    const task = runq orelse break;
                    runq = task.next;
                    self.writeBuffer(tail, task);
                    tail +%= 1;
                }

                self.node_ptr |= DID_INJECT;
                self.runq_tail.storeRelease(tail);

                if (runq != null) {
                    if (is_debug) {
                        const runq_overflow = self.runq_overflow.load();
                        if (runq_overflow != 0)
                            panic("Thread.inject() with non empty runq overflow", .{});
                    }
                    self.runq_overflow.storeRelease(@ptrToInt(runq));
                }
            }

            fn readBuffer(self: *Thread, index: usize) *Task {
                const buffer_ptr = &self.runq_buffer[index % self.runq_buffer.len];
                return @intToPtr(*Task, buffer_ptr.loadUnordered());
            }

            fn writeBuffer(self: *Thread, index: usize, task: *Task) void {
                const buffer_ptr = &self.runq_buffer[index % self.runq_buffer.len];
                buffer_ptr.storeUnordered(@ptrToInt(task));
            }

            pub const Worker = extern struct {
                const max = (~@as(usize, 0)) >> 8;

                ptr: AtomicUsize,

                const Ptr = union(enum) {
                    idle: usize,
                    spawning: *Node,
                    running: *Thread,
                    shutdown: ?Handle,

                    fn fromUsize(value: usize) Ptr {
                        return switch (value & 0b11) {
                            0 => Ptr{ .idle = value >> 2 },
                            1 => Ptr{ .spawning = @intToPtr(*Node, value & ~@as(usize, 0b11)) },
                            2 => Ptr{ .running = @intToPtr(*Thread, value & ~@as(usize, 0b11)) },
                            3 => Ptr{ .shutdown = @intToPtr(?Handle, value & ~@as(usize, 0b11)) },
                            else => unreachable,
                        };
                    }

                    fn toUsize(self: Ptr) usize {
                        switch (self) {
                            .idle => |worker_index| {
                                if (is_debug and worker_index > Worker.max)
                                    panic("Worker.Ptr.toUsize() with invalid worker index of {}", .{worker_index});
                                return (worker_index << 2) | 0;
                            },
                            .spawning => |node| {
                                if (@alignOf(Node) < 4)
                                    @compileError("Worker.Ptr.toUsize() unsupported Node alignment");
                                return @ptrToInt(node) | 1;
                            },
                            .running => |thread| {
                                if (@alignOf(Thread) < 4)
                                    @compileError("Worker.Ptr.toUsize() unsupported Thread alignment");
                                return @ptrToInt(thread) | 2;
                            },
                            .shutdown => |handle| {
                                if (@alignOf(Handle) < 4)
                                    @compileError("Worker.Ptr.toUsize() unsupported Handle alignment");
                                return @ptrToInt(handle) | 3;
                            },
                        }   
                    }
                };
            };
        };

        pub const Node = extern struct {
            next: ?*Node,
            scheduler: *Scheduler,
            workers_ptr: [*]Worker,
            workers_len: usize,
            runq_local: AtomicUsize align(cache_align),
            runq_shared: AtomicUsize,
            idle_queue: AtomicUsize align(cache_align),
            active_threads: AtomicUsize,

            pub fn getScheduler(self: Node) *Scheduler {
                return self.scheduler;
            }

            pub fn getWorkers(self: Node) []Worker {
                return self.workers_ptr[0..self.workers_len];
            }

            const Affinity = enum {
                local,
                shared,
            };

            pub fn schedule(self: *Node, batch: Task.Batch, affinity: Affinity) void {
                if (batch.isEmpty())
                    return;

                self.push(batch, affinity);
                self.resumeThread(.{});
            }

            fn push(self: *Node, batch: Task.Batch, affinity: Affinity) void {
                if (batch.isEmpty())
                    return;

                const run_queue_ptr = switch (affinity) {
                    .local => &self.runq_local,
                    .shared => &self.runq_shared,
                };

                var run_queue = run_queue_ptr.load();
                while (true) {
                    batch.tail.next = @intToPtr(?*Task, run_queue);
                    run_queue = run_queue_ptr.compareAndSwapRelease(
                        run_queue,
                        @ptrToInt(batch.head),
                    ) orelse break;
                }
            }

            pub const IterThreads = extern struct {
                index: usize = 0,
                node: *Node,

                pub fn next(self: *IterThreads) ?*Thread {
                    const workers_ptr = node.workers_ptr;
                    const workers_len = node.workers_len;

                    while (self.index < workers_len) {
                        const worker_index = self.index;
                        self.index += 1;

                        const worker_ptr = workers_ptr[worker_index].ptr.loadAcquire();
                        switch (Worker.Ptr.fromUsize(worker_ptr)) {
                            .idle => {},
                            .spawning => {},
                            .thread => |thread| return thread,
                            .shutdown => panic("IterThread.next() found worker {} shutdown", .{worker_index}),
                        }
                    }

                    return null;
                }
            };

            pub fn iterThreads(self: *Node) IterThreads {
                return IterThreads{ .node = self };
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

            pub const Cluster = extern struct {
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
            active_nodes: AtomicUsize,

            pub const Config = union(enum) {
                smp: Smp,
                numa: Numa,
            };

            fn ReturnTypeOf(comptime function: anytype) type {
                return @typeInfo(@TypeOf(function)).Fn.ReturnType;
            }

            pub fn runAsync(
                config: Config,
                comptime asyncFn: anytype,
                args: anytype,
            ) !ReturnTypeOf(asyncFn) {
                return config.withNuma(runAsyncWithNuma);
            }

            pub fn runAsync(
                config: Config,
                comptime asyncFn: anytype,
                args: anytype,
            ) !ReturnTypeOf(asyncFn) {
                const Arguments = @TypeOf(args);
                const ReturnType = ReturnTypeOf(asyncFn);
                const Wrapper = struct {
                    fn entry(
                        fn_args: Arguments,
                        task_ptr: *Task,
                        result_ptr: *?ReturnType,
                    ) void {
                        suspend task_ptr.* = Task.init(@frame());
                        const result = @call(.{}, asyncFn, fn_args);
                        suspend result_ptr.* = result;
                    }
                };

                var task: Task = undefined;
                var result: ?ReturnType = null;
                var frame = async Wrapper.entry(args, &task, &result);


            }
        };
    };
}

pub const DefaultPlatform = struct {
    const sync = zap.sync.core;
    const Atomic = sync.Atomic;

    pub const task_buffer_size = 256;

    pub const cache_align = sync.cache_line;

    pub const is_debug = std.debug.runtime_safety;

    pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
        return std.debug.panic(fmt, args);
    }

    pub const ThreadLocal = extern struct {
        threadlocal var tls: usize = 0;

        fn get(self: ThreadLocal) usize {
            return tls;
        }

        fn set(self: ThreadLocal, value: usize) void {
            tls = value;
        }
    };

    pub const AtomicUsize = extern struct {
        value: usize,

        pub fn init(value: usize) AtomicUsize {
            return AtomicUsize{ .value = value }
        }

        pub fn get(self: AtomicUsize) usize {
            return self.value;
        }

        pub fn set(self: *AtomicUsize, value: usize) void {
            self.value = value;
        }

        pub fn load(self: *const AtomicUsize) usize {
            return Atomic.load(&self.value, .relaxed);
        }

        pub fn loadUnordered(self: *const AtomicUsize) usize {
            return Atomic.load(&self.value, .unordered);
        }

        pub fn loadAcquire(self: *const AtomicUsize) usize {
            return Atomic.load(&self.value, .acquire);
        }

        pub fn store(self: *AtomicUsize, value: usize) void {
            Atomic.store(&self.value, value, .relaxed);
        }

        pub fn storeUnordered(self: *AtomicUsize, value: usize) void {
            Atomic.store(&self.value, value, .unordered);
        }

        pub fn storeRelease(self: *AtomicUsize, value: usize) void {
            Atomic.store(&self.value, value, .release);
        }

        pub fn swapAcquire(self: *AtomicUsize, value: usize) usize {
            return Atomic.update(&self.value, .swap, value, .acquire);
        }

        pub fn compareAndSwap(self: *AtomicUsize, cmp: usize, xchg: usize) ?usize {
            return Atomic.compareAndSwap(.weak, &self.value, cmp, xchg, .relaxed, .relaxed);
        }

        pub fn compareAndSwapAcquire(self: *AtomicUsize, cmp: usize, xchg: usize) ?usize {
            return Atomic.compareAndSwap(.weak, &self.value, cmp, xchg, .acquire, .relaxed);
        }

        pub fn compareAndSwapRelease(self: *AtomicUsize, cmp: usize, xchg: usize) ?usize {
            return Atomic.compareAndSwap(.weak, &self.value, cmp, xchg, .release, .relaxed);
        }

        pub fn compareAndSwapAcquireRelease(self: *AtomicUsize, cmp: usize, xchg: usize) ?usize {
            return Atomic.compareAndSwap(.weak, &self.value, cmp, xchg, .acq_rel, .acquire);
        }
    };

    pub const Event = extern struct {

        pub fn yield(self: *Event) void {
            std.SpinLock.loopHint(1);
        }
    };
};