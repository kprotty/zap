// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const atomic = @import("../sync/atomic.zig");

const Lock = @import("./lock.zig").Lock;
const Tree = @import("./treap.zig").Treap(struct {
    deadline: u64,

    const Self = @This();

    pub fn isEqual(self: Self, other: Self) bool {
        return self.deadline == other.deadline;
    }

    pub fn isLessThan(self: Self, other: Self) bool {
        return self.deadline < other.deadline;
    }

    pub const use_min = true;

    pub fn isMoreImportant(self: Self, other: Self) bool {
        return self.deadline > other.deadline;
    }
});

pub const Timer = struct {
    tree: Tree = .{},

    pub const Node = struct {
        tree_node: Tree.Node,
        prev: ?*Node,
        next: ?*Node,
        tail: ?*Node,

        pub fn isScheduled(self: *const Node) bool {
            return atomic.load(&self.tail, .Relaxed) != null;
        }

        fn setScheduled(self: *Node) void {
            atomic.store(&self.tail, null, .Relaxed);
        }
    };

    pub fn schedule(self: *Timer, node: *Node, deadline: u64) void {
        node.* = .{
            .tree_node = undefined,
            .prev = null,
            .next = null,
            .tail = node,
        };

        const key = Tree.Key{ .deadline = deadline };
        const lookup = self.tree.find(key);
        const head_tree_node = lookup.node orelse {
            self.tree.insert(lookup, &node.tree_node, key);
            return;
        };

        const head = @fieldParentPtr(Node, "tree_node", head_tree_node);
        const tail = head.tail orelse unreachable;
        tail.next = node;
        node.prev = tail;
        head.tail = node;
    }

    pub fn tryCancel(self: *Timer, node: *Node) bool {
        if (!node.isScheduled())
            return false;
        defer node.setScheduled();

        if (node.prev) |prev| {
            if (node.next) |next| {
                prev.next = next;
                next.prev = prev;
            } else {
                const key = Tree.Key{ .deadline = node.deadline };
                const head_tree_node = self.tree.find(key).node orelse unreachable;
                const head = @fieldParentPtr(Node, "tree_node", head_tree_node);
                head.tail = prev;
                prev.next = null;
            }
        } else {
            if (head.next) |new_head| {
                new_head.tail = head.tail;
                self.tree.replace(&head.tree_node, &new_head.tree_node);
            } else {
                self.tree.remove(&head.tree_node);
            }
        }

        return true;
    }

    pub const Expired = struct {
        head: ?*Node = null,
        tail: *Node = undefined,

        fn push(self: *Expired, node: *Node) void {
            node.next = null;
            if (self.head == null) {
                self.head = node;
                self.tail = node;
            } else {
                self.tail.next = node;
                self.tail = node;
            }
        }

        pub fn isEmpty(self: Expired) bool {
            return self.head == null;
        }

        pub fn next(self: *Expired) ?*Node {
            const node = self.head orelse return null;
            self.head = node.next;
            return node;
        }
    };

    pub fn expiresAt(self: Timer) ?u64 {
        const tree_node = self.tree.peekMin() orelse return null;
        return tree_node.key.deadline;
    }

    pub fn update(self: *Timer, current_time: u64) Expired {
        var expired = Expired{};

        while (true) {
            const tree_node = self.tree.peekMin() orelse break;
            if (current_time >= tree_node.key.deadline) {
                self.tree.remove(tree_node);
            } else {
                break;
            }

            var expired_node: ?*Node = @fieldParentPtr(Node, "tree_node", tree_node);
            while (true) {
                const node = expired_node orelse break;
                expired_node = node.next;

                std.debug.assert(node.isScheduled());
                node.setScheduled();
                expired.push(node);
            }
        }

        return expired;
    }
};

/// Clock sources used to get the current time in nanoseconds under a given context.
pub const ClockSource = enum {
    // Configurable calendar time relative to UTC 1970-01-01.
    System,
    // Time which is precise and never moves backwards.
    Monotonic,
};

pub fn now(comptime source: ClockSource) switch (source) {
    .System => i128,
    .Monotonic => u64,
} {
    atomic.compilerFence(.SeqCst);
    const now_ts = switch (source) {
        .System => return Clock.readSystem(),
        .Monotonic => Clock.readMonotonic(),
    };

    if (Clock.is_actually_monotonic)
        return now_ts;

    const Static = struct {
        var last_ts: u64 = 0;
        var last_lock = Lock{};
    };

    // Try to use atomics instead of locking if they're available
    if (@sizeOf(usize) >= @sizeOf(u64)) {
        var last_ts = atomic.load(&Static.last_ts, .Relaxed);
        while (true) {
            if (now_ts <= last_ts)
                return last_ts;
            last_ts = atomic.tryCompareAndSwap(
                &Static.last_ts,
                last_ts,
                now_ts,
                .Relaxed,
                .Relaxed,
            ) orelse return now_ts;
        }
    }

    const held = Static.last_lock.acquire();
    defer held.release();

    if (Static.last_ts < now_ts)
        Static.last_ts = now_ts;
    return Static.last_ts;
}

const Clock = if (std.builtin.os.tag == .windows)
    WindowsClock
else if (std.Target.current.isDarwin())
    DarwinClock
else if (std.builtin.os.tag == .linux)
    LinuxClock
else if (std.builtin.link_libc)
    PosixClock
else
    @compileError("Unimplemented Clock primitive for platform");

const WindowsClock = struct {
    const is_actually_monotonic = false;

    fn readMonotonic() u64 {}

    fn readSystem() i128 {}
};

const DarwinClock = struct {
    const is_actually_monotonic = false;

    fn readMonotonic() u64 {}

    fn readSystem() i128 {}
};

const LinuxClock = struct {
    const is_actually_monotonic = false;

    fn readMonotonic() u64 {}

    fn readSystem() i128 {}
};

const PosixClock = struct {
    const is_actually_monotonic = false;

    fn readMonotonic() u64 {}

    fn readSystem() i128 {}
};
