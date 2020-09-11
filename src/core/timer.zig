// =============================================================
// Zig port of timeout.c - Tickless hierarchical timing wheel.
// https://github.com/wahern/timeout/blob/master/timeout.c
// =============================================================

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

const min = std.math.min;
const max = std.math.max;
const IntType = std.meta.Int;
const Log2Int = std.math.Log2Int;
const bitCount = std.meta.bitCount;

fn boolToInt(b: bool) u1 {
    return @boolToInt(b);
}

fn cast(comptime T: type, n: anytype) T {
    return @intCast(T, n);
}

fn truncate(comptime T: type, n: anytype) T {
    return @truncate(T, n);
}

fn ctz(n: anytype) @TypeOf(n) {
    return @ctz(@TypeOf(n), n);
}

fn clz(n: anytype) @TypeOf(n) {
    return @clz(@TypeOf(n), n);
}

fn fls(n: anytype) @TypeOf(n) {
    return bitCount(@TypeOf(n)) - clz(n);
}

fn rotl(n: anytype, c: anytype) @TypeOf(n) {
    return std.math.rotl(@TypeOf(n), n, c);
}

fn rotr(n: anytype, c: anytype) @TypeOf(n) {
    return std.math.rotr(@TypeOf(n), n, c);
}

const Node = extern struct {
    prev: ?*Node = null,
    next: ?*Node = null,
    last: *Node = undefined,

    const Queue = extern struct {
        head: ?*Node = null,

        fn isEmpty(self: Queue) bool {
            return self.head == null;
        }

        fn push(self: *Queue, node: *Node) void {
            node.next = null;
            node.last = node;

            if (self.head) |head| {
                node.prev = head.last;
                head.last.next = node;
                head.last = node;
            } else {
                node.prev = null;
                self.head = node;
            }
        }

        fn pop(self: *Queue) ?*Node {
            const node = self.head orelse return null;
            self.remove(node);
            return node;
        }

        fn remove(self: *Queue, node: *Node) void {
            const head = self.head orelse return;

            if (node.prev) |prev|
                prev.next = node.next;
            if (node.next) |next|
                next.prev = node.prev;

            if (node == head) {
                self.head = node.next;
                if (self.head) |new_head|
                    new_head.last = node.last;
            } else if (node == head.last) {
                if (node.prev) |prev|
                    head.last = prev;
            }

            node.prev = null;
            node.next = null;
            node.last = node;
        }

        fn consume(self: *Queue, other: *Queue) void {
            const other_head = other.head orelse return;

            if (self.head) |head| {
                head.last.next = other_head;
                head.last = other_head.last;
            } else {
                self.head = other_head;
            }

            other.* = Queue{};
        }
    };
};

pub const DefaultWheel = Wheel(u64, 6, 4);

pub fn Wheel(
    comptime timeout_t: type,
    comptime wheel_bit: comptime_int,
    comptime wheel_num: comptime_int,
) type {
    const abstime_t = timeout_t;
    const reltime_t = timeout_t;
    const wheel_t = IntType(false, 1 << wheel_bit);
    const wheel_slot_t = Log2Int(wheel_t);

    const wheel_len = 1 << wheel_bit;
    const wheel_max = wheel_len - 1;
    const wheel_mask = wheel_len - 1;
    const timeout_max = (@as(timeout_t, 1) << (wheel_bit * wheel_num)) - 1;

    return extern struct {
        const Self = @This();

        pub const Tick = timeout_t;

        pub const Entry = extern struct {
            node: Node = Node{},
            queue: ?*Node.Queue = null,
            expires: timeout_t = 0,

            fn fromNode(node: *Node) *Entry {
                return @fieldParentPtr(Entry, "node", node);
            }
        };

        wheel: [wheel_num][wheel_len]Node.Queue = [_][wheel_len]Node.Queue{[_]Node.Queue{Node.Queue{}} ** wheel_len} ** wheel_num,
        pending: [wheel_num]wheel_t = [_]wheel_t{0} ** wheel_num,
        expired: Node.Queue = Node.Queue{},
        curtime: timeout_t = 0,

        pub fn now(self: Self) timeout_t {
            return self.curtime;
        }

        pub fn remove(self: *Self, entry: *Entry) void {
            std.debug.assert(self.tryRemove(entry));
        }

        pub fn tryRemove(self: *Self, entry: *Entry) bool {
            const queue = entry.queue orelse return false;
            const node = &entry.node;

            entry.queue = null;
            queue.remove(node);

            if ((queue != &self.expired) and queue.isEmpty()) {
                const index = (@ptrToInt(queue) - @ptrToInt(&self.wheel[0][0])) / @sizeOf(Node.Queue);
                const wheel = index / wheel_len;
                const slot = index % wheel_len;
                self.pending[wheel] &= ~(@as(wheel_t, 1) << cast(wheel_slot_t, slot));
            }

            return true;
        }
        
        pub const expireAt = schedule;
        pub fn schedule(self: *Self, entry: *Entry, expires: timeout_t) void {
            const Timeout = struct {
                fn rem(_self: *Self, _entry: *Entry) reltime_t {
                    return _entry.expires - _self.curtime;
                }

                fn wheel(_timeout: timeout_t) timeout_t {
                    std.debug.assert(_timeout > 0);
                    const w = fls(min(_timeout, timeout_max));
                    return (w - 1) / wheel_bit;
                }

                fn slot(_wheel: timeout_t, _expires: timeout_t) wheel_slot_t {
                    const shift = cast(Log2Int(timeout_t), _wheel) * wheel_bit;
                    return truncate(wheel_slot_t, (_expires >> shift) - boolToInt(_wheel != 0));
                }
            };

            entry.expires = expires;

            var new_queue: *Node.Queue = undefined;
            if (expires > self.curtime) {
                const rem = Timeout.rem(self, entry);
                const wheel = Timeout.wheel(rem);
                const slot = Timeout.slot(wheel, entry.expires);
                self.pending[cast(usize, wheel)] |= @as(wheel_t, 1) << slot;
                new_queue = &self.wheel[cast(usize, wheel)][cast(usize, slot)];
            } else {
                new_queue = &self.expired;
            }

            entry.queue = new_queue;
            new_queue.push(&entry.node);
        }

        pub const expireAfter = add;
        pub fn add(self: *Self, entry: *Entry, timeout: reltime_t) void {
            self.schedule(entry, self.now() + timeout);
        }

        pub fn update(self: *Self, new_now: abstime_t) void {
            const old_now = self.curtime;
            self.curtime = new_now;
            if (new_now <= old_now)
                return;

            var processed = Node.Queue{};
            var elapsed = new_now - old_now;

            for (self.pending) |*mask, wheel| {
                var pending: wheel_t = undefined;
                const shift = cast(Log2Int(timeout_t), wheel * wheel_bit);

                if ((elapsed >> shift) > wheel_max) {
                    pending = ~@as(wheel_t, 0);
                } else {
                    const _elapsed = truncate(wheel_t, elapsed >> shift);
                    const _elapsed_rot = (@as(wheel_t, 1) << cast(wheel_slot_t, _elapsed)) - 1; 

                    const oslot = truncate(wheel_t, old_now >> shift);
                    pending = rotl(_elapsed_rot, oslot);

                    const nslot = truncate(wheel_t, new_now >> shift);
                    pending |= rotr(rotl(_elapsed_rot, nslot), _elapsed);
                    pending |= @as(wheel_t, 1) << cast(wheel_slot_t, nslot);
                }

                while ((pending & mask.*) != 0) {
                    const slot = cast(wheel_slot_t, ctz(pending & mask.*));
                    const queue = &self.wheel[cast(usize, wheel)][cast(usize, slot)];
                    processed.consume(queue);
                    mask.* &= ~(@as(wheel_t, 1) << slot);
                }

                if ((pending & 0x1) == 0) {
                    break;
                } else {
                    elapsed = max(elapsed, @as(timeout_t, wheel_len) << shift);
                }
            }

            while (processed.pop()) |node| {
                const entry = Entry.fromNode(node);
                self.remove(entry);
                self.schedule(entry, entry.expires);
            }
        }

        pub const advance = step;
        pub fn step(self: *Self, elapsed: reltime_t) void {
            self.update(self.now() + elapsed);
        }

        pub fn hasExpired(self: Self) bool {
            return !self.expired.isEmpty();
        }

        pub fn getExpired(self: *Self) ?*Entry {
            const node = self.expired.pop() orelse return null;
            return Entry.fromNode(node);
        }

        pub fn hasPending(self: Self) bool {
            const Vector = std.meta.Vector(wheel_num, wheel_t);
            var zeroes: Vector = @splat(wheel_num, @as(wheel_t, 0));
            const pending: Vector = self.pending;

            for (@bitCast([wheel_num]bool, pending == zeroes)) |wheel_has_pending| {
                if (wheel_has_pending) {
                    return true;
                }
            }

            return false;
        }

        pub fn getPendingEstimate(self: Self) ?reltime_t {
            var timeout = ~@as(reltime_t, 0);
            var relmask: reltime_t = 0;
            var has_timeout = false;

            for (self.pending) |mask, wheel| {
                const shift = cast(Log2Int(timeout_t), wheel) * wheel_bit;
                var _timeout: timeout_t = undefined;

                if (mask != 0) {
                    const slot = truncate(wheel_slot_t, self.curtime >> shift);
                    const tmp = ctz(rotr(mask, @as(wheel_t, slot)));
                    _timeout = @as(timeout_t, tmp + boolToInt(wheel != 0)) << shift;
                    _timeout -= relmask & self.curtime;
                    timeout = min(_timeout, timeout);
                    has_timeout = true;
                }

                relmask <<= wheel_bit;
                relmask |= wheel_mask;
            }

            if (!has_timeout)
                return null;
            return timeout;
        }

        pub const Poll = union(enum) {
            expired: *Entry,
            wait_for: Tick,
        };

        pub fn poll(self: *Self) ?Poll {
            if (self.getExpired()) |expired| {
                return Poll{ .expired = expired };
            }

            if (self.getPendingEstimate()) |wait_for| {
                return Poll{ .wait_for = wait_for };
            }

            return null;
        }
    };
}