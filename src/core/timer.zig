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
const rotl = std.math.rotl;
const rotr = std.math.rotr;
const maxInt = std.math.maxInt;
const Log2Int = std.math.Log2Int;
const IntType = std.meta.Int;

fn boolToInt(b: bool) u1 {
    return @boolToInt(b);
}

fn ctz(n: anytype) @TypeOf(n) {
    return @ctz(@TypeOf(n), n);
}

fn fls(n: anytype) usize {
    return std.meta.bitCount(@TypeOf(n)) - @clz(@TypeOf(n), n);
}

fn as(comptime Int: type, value: anytype) Int {
    return @as(Int, value);
}

fn cast(comptime Int: type, value: anytype) Int {
    return @intCast(Int, value);
}

fn truncate(comptime Int: type, value: anytype) Int {
    return @truncate(Int, value);
}

pub const DefaultQueue = Queue(u64, 6, 4);

pub fn Queue(
    comptime timeout_t: type,
    comptime wheel_bit: comptime_int,
    comptime wheel_num: comptime_int,
) type {
    std.debug.assert(wheel_num > 0);
    std.debug.assert(wheel_bit > 0);
    std.debug.assert((1 << (wheel_num * wheel_bit)) - 1 <= maxInt(timeout_t));
    std.debug.assert(@sizeOf(timeout_t) >= @sizeOf(IntType(false, 1 << wheel_bit)));

    const wheel_len = 1 << wheel_bit;
    const wheel_mask = wheel_len - 1;
    const wheel_t = IntType(false, wheel_len);
    const wheel_slot_t = IntType(false, wheel_bit);
    const wheel_num_t = Log2Int(IntType(false, wheel_num));

    return extern struct {
        const Self = @This();

        pub const Entry = List.Node;

        const List = extern struct {
            const Node = extern struct {
                prev: ?*Entry,
                next: ?*Entry,
                last: *Entry,
                list: ?*List,
                expires: timeout_t,
            };

            head: ?*Entry = null,

            fn isEmpty(self: List) bool {
                return self.head == null;
            }

            fn push(self: *List, entry: *Entry) void {
                entry.next = null;
                entry.last = entry;
                if (self.head) |head| {
                    entry.prev = head.last;
                    head.last.next = entry;
                    head.last = entry;
                } else {
                    entry.prev = null;
                    self.head = entry;
                }
            }

            fn pop(self: *List) ?*Entry {
                const entry = self.head orelse return null;
                self.remove(entry);
                return entry;
            }

            fn remove(self: *List, entry: *Entry) void {
                const head = self.head orelse return;

                if (entry.prev) |prev| {
                    prev.next = entry.next;
                    if (head.last == entry)
                        head.last = prev;
                }
                
                if (entry.next) |next|
                    next.prev = entry.prev;
                if (head == entry)
                    self.head = entry.next;

                entry.next = null;
                entry.prev = null;
                entry.last = entry;
            }

            fn consume(self: *List, other: *List) void {
                const other_head = other.head orelse return;

                if (self.head) |head| {
                    other_head.prev = head.last;
                    head.last.next = other_head;
                    head.last = other_head.last;
                } else {
                    self.* = other.*;
                }

                other.* = List{};
            }
        };

        wheel: [wheel_num][wheel_len]List = [_][wheel_len]List{[_]List{List{}} ** wheel_len} ** wheel_num,
        pending: [wheel_num]wheel_t = [_]wheel_t{0} ** wheel_num,
        expired: List = List{},
        current: timeout_t = 0,

        pub fn now(self: Self) timeout_t {
            return self.current;
        }

        pub fn expireAfter(self: *Self, entry: *Entry, duration: timeout_t) void {
            self.expireAt(entry, self.now() + duration);
        }

        pub fn expireAt(self: *Self, entry: *Entry, deadline: timeout_t) void {
            const current = self.now();

            var list: *List = undefined;
            if (deadline <= current) {
                list = &self.expired;
            } else {
                const rem = deadline - current;
                const wheel = truncate(wheel_num_t, (cast(Log2Int(timeout_t), fls(min(rem, maxInt(timeout_t)))) - 1) / wheel_bit);
                const slot = truncate(wheel_slot_t, (deadline >> (cast(Log2Int(timeout_t), wheel) * wheel_bit)) - boolToInt(wheel != 0));
                self.pending[wheel] |= as(wheel_t, 1) << slot;
                list = &self.wheel[wheel][slot];
            }

            entry.list = list;
            entry.expires = deadline;
            list.push(entry);
        }

        pub const remove = invalidate;
        pub fn invalidate(self: *Self, entry: *Entry) void {
            const list = entry.list orelse return;
            entry.list = null;
            list.remove(entry);

            if ((list != &self.expired) and list.isEmpty()) {
                const index = (@ptrToInt(list) - @ptrToInt(&self.wheel[0][0])) / @sizeOf(List);
                const wheel = cast(wheel_num_t, index / wheel_len);
                const slot = cast(wheel_slot_t, index % wheel_len);
                self.pending[wheel] &= ~(as(wheel_t, 1) << slot);
            }
        }

        pub fn advance(self: *Self, duration: timeout_t) void {
            self.update(self.now() + duration);
        }

        pub fn update(self: *Self, new_now: timeout_t) void {
            const old_now = self.now();
            self.current = new_now;
            if (new_now <= old_now)
                return;

            var processed = List{};
            var processed_last: ?*Entry = null;
            var elapsed = new_now - old_now;

            for (self.pending) |*mask, wheel| {
                var pending_slots: wheel_t = undefined;

                const offset = cast(Log2Int(timeout_t), wheel) * wheel_bit;
                if ((elapsed >> offset) > wheel_mask) {
                    pending_slots = ~as(wheel_t, 0);
                } else {
                    const _elapsed = truncate(wheel_slot_t, elapsed >> offset);
                    const _rslot = (as(wheel_t, 1) << _elapsed) - 1;

                    const _oslot = truncate(wheel_slot_t, old_now >> offset);
                    pending_slots = rotl(wheel_t, _rslot, cast(wheel_t, _oslot));

                    const _nslot = truncate(wheel_slot_t, new_now >> offset);
                    const _nslotl = rotl(wheel_t, _rslot, cast(wheel_t, _nslot));
                    const _nslotlr = rotr(wheel_t, _nslotl, cast(wheel_t, _elapsed));
                    pending_slots |= _nslotlr | (as(wheel_t, 1) << _nslot);
                }

                while ((pending_slots & mask.*) != 0) {
                    const slot = truncate(wheel_slot_t, ctz(pending_slots & mask.*));
                    mask.* &= ~(as(wheel_t, 1) << slot);
                    processed.consume(&self.wheel[wheel][slot]);
                }

                elapsed = max(elapsed, as(timeout_t, wheel_len) << offset);
                if ((pending_slots & 0x1) == 0)
                    break;
            }

            while (processed.pop()) |entry| {
                if (entry.list) |list|
                    list.remove(entry);
                self.expireAt(entry, entry.expires);
            }
        }

        pub const Poll = union(enum) {
            expired: *Entry,
            wait_for: timeout_t,
        };

        pub fn poll(self: *Self) ?Poll {
            if (self.get()) |entry| {
                return Poll{ .expired = entry };
            }

            if (self.nextExpire()) |expires_in| {
                return Poll{ .wait_for = expires_in }; 
            }

            return null;
        }

        fn get(self: *Self) ?*Entry {
            return self.expired.pop();
        }

        fn nextExpire(self: Self) ?timeout_t {
            const current = self.now();
            var rel_mask = as(timeout_t, 0);
            var interval = ~rel_mask;
            var has_timeout = false;
            
            for (self.pending) |mask, wheel| {
                if (mask != 0) {
                    const shift = cast(Log2Int(timeout_t), wheel) * wheel_bit;
                    const slot = truncate(wheel_t, current >> shift);
                    const offset = ctz(rotr(wheel_t, mask, as(wheel_t, slot)));
                    const rotated = as(timeout_t, offset + boolToInt(wheel != 0)) << shift;
                    const timeout = rotated - (rel_mask & current);
                    
                    if (timeout != 0) {
                        interval = min(interval, timeout);
                        has_timeout = true;
                    }
                }

                rel_mask <<= wheel_bit;
                rel_mask |= wheel_mask;
            }

            if (has_timeout)
                return interval;
            return null;
        }
    };
}