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

        pub const Task = extern struct {

            pub const Callback = fn(
                noalias *Task,
                noalias *Thread,
            ) callconv(.C) void;

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
            runq_overflow: AtomicUsize,
            runq_local: AtomicUsize,
            runq_next: AtomicUsize,
            runq_head: AtomicUsize,
            runq_tail: AtomicUsize align(cache_line),
            runq_buffer: [task_buffer_size]AtomicUsize align(cache_line),
            runq_owned: ?*Task,
            node_ptr: usize,
            event: Event,

            fn getNode(self: Thread) *Node {
                const node_ptr = self.node_ptr & ~@as(usize, 0b11);
                return @intToPtr(*Node, node_ptr);
            }

            const Affinity = enum {
                owned,
                local,
                shared,
            };

            fn push(self: *Thread, batch: Task.Batch, affinity: Affinity) void {
                if (batch.isEmpty())
                    return;

                switch (affinity) {
                    .owned => self.pushOwned(batch),
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

            fn steal(self: *Thread, target: Target) ?*Task {
                switch (target) {
                    .shared => |thread| {
                        if (self == thread)
                            return self.pop();
                        return self.stealShared(thread);
                    },
                    .global => |node| {
                        if (node == self.getNode()) {
                            if (self.stealGlobal(&node.runq_local)) |task|
                                return task;
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

            fn stealShared(noalias self: *Thread, noalias target: *Thread) ?*Task {
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

                        if (target.runq_next.load() != 0) {
                            const target_next = target.runq_next.swapAcquire(0);
                            if (@intToPtr(?*Task, target_next)) |task|
                                return task;
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

            };
        };

        pub const Node = extern struct {
            workers_ptr: [*]Worker,
            workers_len: usize,
            runq_local: AtomicUsize align(cache_align),
            runq_shared: AtomicUsize,
            idle_queue: AtomicUsize align(cache_align),
            active_threads: AtomicUsize,

            fn push(self: *Node, batch: Task.Batch, affinity: Task.Affinity) void {

            }

            pub const Cluster = extern struct {

            };
        };

        pub const Scheduler = extern struct {

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