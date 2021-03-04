// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const atomic = @import("../sync/atomic.zig");

pub const Node = struct {
    next: ?*Node = null,
};

pub const Batch = struct {
    head: ?*Node = null,
    tail: *Node = undefined,

    pub fn from(node: *Node) Batch {
        node.next = null;
        return Batch{
            .head = node,
            .tail = node,
        };
    }

    pub fn isEmpty(self: Batch) bool {
        return self.head == null;
    }

    pub fn push(self: *Batch, batch: Batch) void {
        if (batch.isEmpty())
            return;

        if (self.isEmpty()) {
            self.* = batch;
        } else {
            self.tail.next = batch.head;
            self.tail = batch.tail;
        }
    }

    pub fn pop(self: *Batch) ?*Node {
        const node = self.head orelse return null;
        self.head = node.next;
        return node;
    }
};

pub const GlobalQueue = struct {
    queue: UnboundedQueue = .{},

    pub fn isEmpty(self: *const GlobalQueue) callconv(.Inline) bool {
        return self.queue.isEmpty();
    }

    pub fn push(self: *GlobalQueue, batch: Batch) callconv(.Inline) void {
        self.queue.push(batch);
    }
};

pub const LocalQueue = struct {
    buffer: BoundedQueue = .{},
    overflow: UnboundedQueue = .{},

    pub fn isEmpty(self: *const LocalQueue) bool {
        return self.buffer.isEmpty() and self.overflow.isEmpty();
    }

    pub fn push(self: *LocalQueue, batch: Batch) void {
        if (self.buffer.push(batch)) |overflowed|
            self.overflow.push(overflowed);
    }

    pub fn pop(self: *LocalQueue, be_fair: bool) ?*Node {
        if (be_fair) {
            if (self.overflow.tryAcquireConsumer()) |*consumer| {
                defer consumer.release();
                if (consumer.pop()) |node|
                    return node;
            }
        }

        if (self.buffer.pop()) |node|
            return node;

        if (self.buffer.popAndSteal(&self.overflow)) |node|
            return node;

        return null;
    }

    pub fn popAndSteal(self: *LocalQueue, target: anytype, be_fair: bool) ?*Node {
        const is_global = switch (@TypeOf(target)) {
            *LocalQueue => false,
            *GlobalQueue => true,
            else => |ty| @compileError("Cannot popAndSteal() from " ++ @typeName(ty)),
        };

        if (is_global) {
            return self.buffer.popAndSteal(&target.queue);
        }

        if (self == target)
            return self.pop(be_fair);

        if (be_fair) {
            if (self.buffer.popAndSteal(&target.overflow)) |node|
                return node;
        }

        if (self.buffer.popAndSteal(&target.buffer)) |node|
            return node;

        if (self.buffer.popAndSteal(&target.overflow)) |node|
            return node;

        return null;
    }
};

pub const UnboundedQueue = struct {
    head: ?*Node = null,
    tail: usize = 0,
    stub: Node = .{},

    pub fn isEmpty(self: *const UnboundedQueue) bool {
        const head = atomic.load(&self.head, .Relaxed);
        return (head == null) or (head == &self.stub);
    }

    pub fn push(self: *UnboundedQueue, batch: Batch) void {
        if (batch.isEmpty())
            return;

        const head = atomic.swap(&self.head, batch.tail, .AcqRel);
        const prev = head orelse &self.stub;
        atomic.store(&prev.next, batch.head, .Release);
    }

    pub fn tryAcquireConsumer(self: *UnboundedQueue) ?Consumer {
        while (true) : (atomic.spinLoopHint()) {
            if (self.isEmpty())
                return null;

            const IS_CONSUMING: usize = 0b1;
            comptime {
                std.debug.assert(@alignOf(*Node) >= (IS_CONSUMING << 1));
            }

            const tail = atomic.load(&self.tail, .Relaxed);
            if (tail & IS_CONSUMING != 0)
                return null;

            _ = atomic.tryCompareAndSwap(
                &self.tail,
                tail,
                tail | IS_CONSUMING,
                .Acquire,
                .Relaxed,
            ) orelse return Consumer{
                .queue = self,
                .tail = @intToPtr(?*Node, tail) orelse &self.stub,
                .stub = &self.stub,
            };
        }
    }

    pub const Consumer = struct {
        queue: *UnboundedQueue,
        tail: *Node,
        stub: *Node,

        pub fn release(self: Consumer) void {
            const new_tail = @ptrToInt(self.tail);
            atomic.store(&self.queue.tail, new_tail, .Release);
        }

        pub fn pop(self: *Consumer) ?*Node {
            var tail = self.tail;
            var next = atomic.load(&tail.next, .Acquire);
            if (tail == self.stub) {
                tail = next orelse return null;
                self.tail = tail;
                next = atomic.load(&tail.next, .Acquire);
            }

            if (next) |node| {
                self.tail = node;
                return tail;
            }

            const head = atomic.load(&self.queue.head, .Relaxed);
            if (tail == head)
                return null;

            self.queue.push(Batch.from(self.stub));
            if (atomic.load(&tail.next, .Acquire)) |node| {
                self.tail = node;
                return tail;
            }

            return null;
        }
    };
};

pub const BoundedQueue = struct {
    head: usize = 0,
    tail: usize = 0,
    buffer: [128]*Node = undefined,

    pub fn isEmpty(self: *const BoundedQueue) bool {
        const tail = atomic.load(&self.tail, .Relaxed);
        const head = atomic.load(&self.head, .Relaxed);
        return tail == head;
    }

    pub fn push(self: *BoundedQueue, _batch: Batch) ?Batch {
        var batch = _batch;
        if (batch.isEmpty())
            return null;

        var tail = self.tail;
        var head = atomic.load(&self.head, .Relaxed);
        while (true) {
            if (batch.isEmpty())
                return null;

            const size = tail -% head;
            if (size < self.buffer.len) {
                var empty = self.buffer.len - size;
                while (empty > 0) : (empty -= 1) {
                    const node = batch.pop() orelse break;
                    atomic.store(&self.buffer[tail % self.buffer.len], node, .Unordered);
                    tail +%= 1;
                }

                atomic.store(&self.tail, tail, .Release);
                if (batch.isEmpty())
                    return null;

                atomic.spinLoopHint();
                head = atomic.load(&self.head, .Relaxed);
                continue;
            }

            const new_head = head +% (self.buffer.len / 2);
            if (atomic.tryCompareAndSwap(
                &self.head,
                head,
                new_head,
                .Acquire,
                .Relaxed,
            )) |updated| {
                atomic.spinLoopHint();
                head = updated;
                continue;
            }

            var overflowed = Batch{};
            while (head != new_head) : (head +%= 1) {
                const node = self.buffer[head % self.buffer.len];
                overflowed.push(Batch.from(node));
            }

            overflowed.push(batch);
            return overflowed;
        }
    }

    pub fn pop(self: *BoundedQueue) ?*Node {}

    pub fn popAndSteal(self: *BoundedQueue, target: anytype) ?*Node {
        const is_unbounded = switch (@TypeOf(target)) {
            *UnboundedQueue => true,
            *BoundedQueue => false,
            else => |T| @compileError("Cannot popAndSteal() from a " ++ @typeName(T)),
        };

        var tail = self.tail;
        var head = atomic.load(&self.head, .Relaxed);
        if (tail != head)
            return self.pop();

        if (is_unbounded) {
            var consumer = target.tryAcquireConsumer() orelse return null;
            defer consumer.release();

            var target_steal: usize = 0;
            var first_node: ?*Node = null;
            head = atomic.load(&self.head, .Relaxed);

            while (true) {
                if (first_node != null) {
                    var size = tail -% head;
                    if (size >= self.buffer.len) {
                        atomic.spinLoopHint();

                        // recheck the head to see if any consumers made some more space
                        head = atomic.load(&self.head, .Relaxed);
                        size = tail -% head;
                        if (size >= self.buffer.len)
                            break;
                    }
                }

                const node = consumer.pop() orelse break;
                if (first_node == null) {
                    first_node = node;
                    continue;
                }

                atomic.store(&self.buffer[tail % self.buffer.len], node, .Unordered);
                target_steal += 1;
                tail +%= 1;
            }

            if (target_steal > 0)
                atomic.store(&self.tail, tail, .Release);
            return first_node;
        }

        while (true) {
            const target_tail = atomic.load(&target.tail, .Acquire);
            const target_head = atomic.load(&target.head, .Relaxed);
            if (target_tail == target_head)
                return null;

            var target_steal = target_tail -% target_head;
            target_steal = target_steal - (target_steal / 2);
            if (target_steal > (self.buffer.len / 2)) {
                atomic.spinLoopHint();
                continue;
            }

            const first_node = atomic.load(&target.buffer[target_head % target.buffer.len], .Unordered);
            target_steal -= 1;

            var steal: usize = 0;
            while (steal < target_steal) : (steal += 1) {
                const node = atomic.load(&target.buffer[(target_head +% steal) % target.buffer.len], .Unordered);
                atomic.store(&self.buffer[(tail +% steal) % self.bufer.len], node, .Unordered);
            }

            if (atomic.compareAndSwap(
                &target.head,
                target_head,
                target_head +% (target_steal + 1),
                .AcqRel,
                .Relaxed,
            )) |_| {
                atomic.spinLoopHint();
                continue;
            }

            if (target_steal > 0)
                atomic.store(&self.tail, tail +% target_steal, .Release);
            return first_node;
        }
    }
};
