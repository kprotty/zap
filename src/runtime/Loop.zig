// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");

const Self = @This();

fn ReturnTypeOf(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).Fn.return_type.?;
}

pub fn run(
    config: struct {
        max_threads: ?usize = null,
        stack_size: ?usize = null,
    },
    comptime entryFn: anytype,
    entryArgs: anytype,
) !ReturnTypeOf(entryFn) {
    const Args = @TypeOf(entryArgs);
    const Result = ReturnTypeOf(entryFn);
    const Wrapper = struct {
        fn entry(task: *Task, result: *?Result, args: Args) void {
            suspend task.* = .{ .frame = @frame() };
            const ret_val = @call(.{}, entryFn, args);
            suspend result.* = ret_val;
        }
    };

    var task: Task = undefined;
    var result: ?Result = null;
    var frame = async Wrapper.entry(&task, &result, entryArgs);
}

pub const Task = struct {
    next: ?*Task = null,
    frame: anyframe,
};

pub const Batch = struct {
    head: ?*Task = null,
    tail: *Task = undefined,

    pub fn from(batchable: anytype) Batch {
        return switch (@TypeOf(batchable)) {
            Batch => batchable,
            ?*Task => from(batchable orelse return .{}),
            *Task => {
                batchable.next = null;
                return .{
                    .head = batchable,
                    .tail = batchable,
                };
            },
            else => |typ| @compileError(@typeName(typ) ++ " cannot be converted into a " ++ @TypeOf(Batch)),
        };
    }

    pub fn isEmpty(self: Batch) bool {
        return self.head == null;
    }

    pub fn push(self: *Batch, batchable: anytype) void {
        const batch = from(batchable);
        if (batch.isEmpty())
            return;

        if (self.isEmpty()) {
            self.* = batch;
        } else {
            self.tail.next = batch.head;
            self.tail = batch.tail;
        }
    }

    pub fn pop(self: *Batch) ?*Task {
        const task = self.head orelse return null;
        self.head = task.next;
        return task;
    }

    pub fn iter(self: Batch) Iter {
        return .{ .current = self.head };
    }

    pub const Iter = struct {
        current: ?*Task,

        pub fn next(self: *Iter) ?*Task {
            const task = self.current orelse return null;
            self.current = task.next;
            return task;
        }
    };
};

const GlobalQueue = UnboundedQueue;
const LocalQueue = struct {
    buffer: BoundedQueue = .{},
    overflow: UnboundedQueue = .{},

    fn push(self: *LocalQueue, batch: Batch) void {
        if (self.buffer.push(batch)) |overflowed|
            self.overflow.push(overflowed);
    }

    fn pop(self: *LocalQueue, tick: usize) ?*Task {
        if (tick % 61 == 0) {
            if (self.buffer.pop()) |task|
                return task;
        }

        if (self.buffer.stealUnbounded(&self.overflow)) |task|
            return task;

        if (self.buffer.pop()) |task|
            return task;

        return null;
    }

    fn popAndStealGlobal(self: *LocalQueue, target: *GlobalQueue) ?*Task {
        return self.buffer.stealUnbounded(target);
    }

    fn popAndStealLocal(self: *LocalQueue, target: *LocalQueue) ?*Task {
        if (self == target)
            return self.pop(1);

        if (self.buffer.stealUnbounded(&target.overflow)) |task|
            return task;

        if (self.buffer.stealBounded(&target.buffer)) |task|
            return task;

        return null;
    }
};

const UnboundedQueue = struct {
    head: ?*Task = null,
    tail: usize = 0,
    stub: Task = Task.init(undefined),

    fn push(self: *UnboundedQueue, batch: Batch) void {
        if (batch.isEmpty()) return;
        const head = @atomicRmw(?*Task, &self.head, .Xchg, batch.tail, .AcqRel);
        const prev = head orelse &self.stub;
        @atomicStore(?*Task, &prev.next, batch.head, .Release);
    }

    fn tryAcquireConsumer(self: *UnboundedQueue) ?Consumer {
        var tail = @atomicLoad(usize, &self.tail, .Monotonic);
        while (true) : (std.Thread.spinLoopHint()) {
            const head = @atomicLoad(?*Task, &self.head, .Monotonic);
            if (head == null or head == &self.stub)
                return null;

            if (tail & 1 != 0)
                return null;
            tail = @cmpxchgWeak(
                usize,
                &self.tail,
                tail,
                tail | 1,
                .Acquire,
                .Monotonic,
            ) orelse return Consumer{
                .queue = self,
                .tail = @intToPtr(?*Task, tail) orelse &self.stub,
            };
        }
    }

    const Consumer = struct {
        queue: *UnboundedQueue,
        tail: *Task,

        fn release(self: Consumer) void {
            @atomicStore(usize, &self.queue.tail, @ptrToInt(self.tail), .Release);
        }

        fn pop(self: *Consumer) ?*Task {
            var tail = self.tail;
            var next = @atomicLoad(?*Task, &tail.next, .Acquire);
            if (tail == &self.queue.stub) {
                tail = next orelse return null;
                self.tail = tail;
                next = @atomicLoad(?*Task, &tail.next, .Acquire);
            }

            if (next) |task| {
                self.tail = task;
                return tail;
            }

            const head = @atomicLoad(?*Task, &self.queue.head, .Monotonic);
            if (tail != head) {
                return null;
            }

            self.queue.push(Batch.from(&self.queue.stub));
            if (@atomicLoad(?*Task, &tail.next, .Acquire)) |task| {
                self.tail = task;
                return tail;
            }

            return null;
        }
    };
};

const BoundedQueue = struct {
    head: Pos = 0,
    tail: Pos = 0,
    buffer: [capacity]*Task = undefined,

    const Pos = std.meta.Int(.unsigned, std.meta.bitCount(usize) / 2);
    const capacity = 64;
    comptime {
        std.debug.assert(capacity <= std.math.maxInt(Pos));
    }

    fn push(self: *BoundedQueue, _batch: Batch) ?Batch {
        var batch = _batch;
        if (batch.isEmpty()) {
            return null;
        }

        var tail = self.tail;
        var head = @atomicLoad(Pos, &self.head, .Monotonic);
        while (true) {
            if (batch.isEmpty())
                return null;

            if (tail -% head < self.buffer.len) {
                while (tail -% head < self.buffer.len) {
                    const task = batch.pop() orelse break;
                    @atomicStore(*Task, &self.buffer[tail % self.buffer.len], task, .Unordered);
                    tail +%= 1;
                }

                @atomicStore(Pos, &self.tail, tail, .Release);
                std.Thread.spinLoopHint();
                head = @atomicLoad(Pos, &self.head, .Monotonic);
                continue;
            }

            const new_head = head +% @intCast(Pos, self.buffer.len / 2);
            if (@cmpxchgWeak(
                Pos,
                &self.head,
                head,
                new_head,
                .Acquire,
                .Monotonic,
            )) |updated| {
                head = updated;
                continue;
            }

            var overflowed = Batch{};
            while (head != new_head) : (head +%= 1) {
                const task = self.buffer[head % self.buffer.len];
                overflowed.pushBack(Batch.from(task));
            }

            overflowed.pushBack(batch);
            return overflowed;
        }
    }

    fn pop(self: *BoundedQueue) ?*Task {
        var tail = self.tail;
        var head = @atomicLoad(Pos, &self.head, .Monotonic);

        while (tail != head) : (std.Thread.spinLoopHint()) {
            head = @cmpxchgWeak(
                Pos,
                &self.head,
                head,
                head +% 1,
                .Acquire,
                .Monotonic,
            ) orelse return self.buffer[head % self.buffer.len];
        }

        return null;
    }

    fn stealUnbounded(self: *BoundedQueue, target: *UnboundedQueue) ?*Task {
        var consumer = target.tryAcquireConsumer() orelse return null;
        defer consumer.release();

        const first_task = consumer.pop();
        const head = @atomicLoad(Pos, &self.head, .Monotonic);
        const tail = self.tail;

        var new_tail = tail;
        while (new_tail -% head < self.buffer.len) {
            const task = consumer.pop() orelse break;
            @atomicStore(*Task, &self.buffer[new_tail % self.buffer.len], task, .Unordered);
            new_tail +%= 1;
        }

        if (new_tail != tail)
            @atomicStore(Pos, &self.tail, new_tail, .Release);
        return first_task;
    }

    fn stealBounded(self: *BoundedQueue, target: *BoundedQueue) ?*Task {
        if (self == target)
            return self.pop();

        const head = @atomicLoad(Pos, &self.head, .Monotonic);
        const tail = self.tail;
        if (tail != head)
            return self.pop();

        var target_head = @atomicLoad(Pos, &target.head, .Monotonic);
        while (true) {
            const target_tail = @atomicLoad(Pos, &target.tail, .Acquire);
            const target_size = target_tail -% target_head;
            if (target_size == 0)
                return null;

            var steal = target_size - (target_size / 2);
            if (steal > target.buffer.len / 2) {
                std.Thread.spinLoopHint();
                target_head = @atomicLoad(Pos, &target.head, .Monotonic);
                continue;
            }

            const first_task = @atomicLoad(*Task, &target.buffer[target_head % target.buffer.len], .Unordered);
            var new_target_head = target_head +% 1;
            var new_tail = tail;
            steal -= 1;

            while (steal > 0) : (steal -= 1) {
                const task = @atomicLoad(*Task, &target.buffer[new_target_head % target.buffer.len], .Unordered);
                new_target_head +%= 1;
                @atomicStore(*Task, &self.buffer[new_tail % self.buffer.len], task, .Unordered);
                new_tail +%= 1;
            }

            if (@cmpxchgWeak(
                Pos,
                &target.head,
                target_head,
                new_target_head,
                .AcqRel,
                .Monotonic,
            )) |updated| {
                std.Thread.spinLoopHint();
                target_head = updated;
                continue;
            }

            if (new_tail != tail)
                @atomicStore(Pos, &self.tail, new_tail, .Release);
            return first_task;
        }
    }
};
