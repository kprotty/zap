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
const zap = @import("../../zap.zig");

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        const Waiter = struct {
            next: ?*Waiter,
            last: *Waiter,
            task: zap.Task,
            item: Item,

            const Item = union(enum) {
                some: T,
                none: void,
                closed: void,
            };

            const Queue = struct {
                head: ?*Waiter = null,

                fn push(self: *Queue, waiter: *Waiter) void {
                    waiter.next = null;
                    waiter.last = waiter;
                    if (self.head) |head| {
                        head.last.next = waiter;
                        head.last = waiter;
                    } else {
                        self.head = waiter;
                    }
                }

                fn pop(self: *Queue) ?*Waiter {
                    const waiter = self.head orelse return null;
                    self.head = waiter.next;
                    return waiter;
                }

                fn consume(self: *Queue, other: *Queue) void {
                    const other_head = other.head orelse return;
                    other.head = null;
                    if (self.head) |head| {
                        head.last.next = other_head;
                        head.last = other_head.last;
                    } else {
                        self.head = other_head;
                    }
                }
            };
        };

        const Held = struct {
            next: ?*Held,
            task: zap.Task,

            const Lock = struct {
                tail: ?*Held = null,

                fn acquire(self: *Lock, held: *Held) void {
                    suspend {
                        held.next = null;
                        held.task = zap.Task.init(@frame());

                        const prev = @atomicRmw(?*Held, &self.tail, .Xchg, held, .AcqRel);
                        if (prev) |tail| {
                            tail.next = held;
                        } else {
                            resume @frame();
                        }
                    }
                }

                fn release(self: *Lock, held: *Held) ?*zap.Task {
                    _ = @cmpxchgStrong(
                        ?*Held,
                        &self.tail,
                        held,
                        null,
                        .Release,
                        .Monotonic,
                    ) orelse return null;

                    var spin: u4 = 0;
                    while (true) {
                        if (@atomicLoad(?*Held, &held.next, .Acquire)) |next|
                            return &next.task;

                        if (spin <= 3) {
                            spin += 1;
                            zap.sync.spinLoopHint(@as(usize, 1) << spin);
                        } else {
                            zap.sync.os.Signal.yield();
                        }
                    }
                }
            };
        };

        lock: Held.Lock = Held.Lock{},
        putters: Waiter.Queue = Waiter.Queue{},
        getters: Waiter.Queue = Waiter.Queue{},
        head: usize = 0,
        tail: usize = 0,
        buffer_ptr: ?[*]T,
        buffer_len: usize,

        pub fn init(buffer: []T) Self {
            return Self{
                .buffer_ptr = buffer.ptr,
                .buffer_len = buffer.len,
            };
        }

        pub fn deinit(self: *Self) void {
            self.close();
        }

        pub fn close(self: *Self) void {
            var held: Held = undefined;
            self.lock.acquire(&held);

            self.buffer_ptr = null;

            var waiters = Waiter.Queue{};
            waiters.consume(&self.putters);
            waiters.consume(&self.getters);

            var batch = zap.Task.Batch{};
            if (self.lock.release(&held)) |unlock_task|
                batch.push(unlock_task);

            while (waiters.pop()) |waiter| {
                batch.push(&waiter.task);
                waiter.item = Waiter.Item{ .closed = {} };
            }

            batch.schedule();
        }

        pub fn tryGet(self: *Self) error{Empty, Closed}!T {
            var held: Held = undefined;
            self.lock.acquire(&held);
            
            var batch = zap.Task.Batch{};
            var result: error{Empty, Closed}!T = undefined;
            
            if (self.buffer_ptr) |buffer_ptr| {
                if (self.putters.pop()) |waiter| {
                    batch.push(&waiter.task);
                    result = waiter.item.some;
                    waiter.item = Waiter.Item{ .none = {} };

                } else if (self.tail == self.head) {
                    result = error.Empty;

                } else {
                    result = buffer_ptr[self.head % self.buffer_len];
                    self.head +%= 1;
                }
            } else {
                result = error.Closed;
            }

            if (self.lock.release(&held)) |unlock_task|
                batch.pushFront(unlock_task);

            batch.schedule();
            return result;
        }

        pub fn tryPut(self: *Self, item: T) error{Full, Closed}!void {
            var held: Held = undefined;
            self.lock.acquire(&held);
            
            var batch = zap.Task.Batch{};
            var result: error{Full, Closed}!T = undefined;

            if (self.buffer_ptr) |buffer_ptr| {
                if (self.getters.pop()) |waiter| {
                    batch.push(&waiter.task);
                    result = {};
                    waiter.item = Waiter.Item{ .some = item };

                } else if (self.tail -% self.head >= self.buffer_len) {
                    result = error.Full;

                } else {
                    buffer_ptr[self.tail % self.buffer_len] = item;
                    self.tail +%= 1;
                    result = {};
                }
            } else {
                result = error.Closed;
            }

            if (self.lock.release(&held)) |unlock_task|
                batch.pushFront(unlock_task);

            batch.schedule();
            return result;
        }

        pub fn put(self: *Self, item: T) error{Closed}!void {
            var held: Held = undefined;
            self.lock.acquire(&held);
            
            const buffer_ptr = self.buffer_ptr orelse {
                if (self.lock.release(&held)) |unlock_task|
                    unlock_task.schedule();
                return error.Closed;
            };

            if (self.getters.pop()) |waiter| {
                var batch = zap.Task.Batch{};
                if (self.lock.release(&held)) |unlock_task|
                    batch.push(unlock_task);

                suspend {
                    const thread = zap.Task.getCurrentThread();
                    waiter.item = Waiter.Item{ .some = item };
                    if (thread.scheduleNext(&waiter.task)) |old_next|
                        batch.pushFront(old_next);

                    var task = zap.Task.init(@frame());
                    batch.push(&task);
                    thread.schedule(batch);
                }

                return;
            }

            if (self.tail -% self.head < self.buffer_len) {
                buffer_ptr[self.tail % self.buffer_len] = item;
                self.tail +%= 1;

                if (self.lock.release(&held)) |unlock_task|
                    unlock_task.schedule();

                return;
            }

            var waiter: Waiter = undefined;
            waiter.task = zap.Task.init(@frame());
            waiter.item = Waiter.Item{ .some = item };
            self.putters.push(&waiter);

            suspend {
                if (self.lock.release(&held)) |unlock_task| {
                    const thread = zap.Task.getCurrentThread();
                    if (thread.scheduleNext(unlock_task)) |old_next|
                        thread.schedule(zap.Task.Batch.from(old_next));
                }
            }

            return switch (waiter.item) {
                .some => unreachable,
                .none => {},
                .closed => error.Closed,
            };
        }

        pub fn get(self: *Self) error{Closed}!T {
            var held: Held = undefined;
            self.lock.acquire(&held);
            
            const buffer_ptr = self.buffer_ptr orelse {
                if (self.lock.release(&held)) |unlock_task|
                    unlock_task.schedule();
                return error.Closed;
            };

            if (self.putters.pop()) |waiter| {
                var batch = zap.Task.Batch{};
                if (self.lock.release(&held)) |unlock_task|
                    batch.push(unlock_task);

                const item = switch (waiter.item) {
                    .some => |item| item,
                    .none => unreachable,
                    .closed => unreachable,
                };
                waiter.item = Waiter.Item{ .none = {} };

                batch.push(&waiter.task);
                batch.schedule();
                
                return item;
            }

            if (self.tail != self.head) {
                const item = buffer_ptr[self.head % self.buffer_len];
                self.head +%= 1;

                if (self.lock.release(&held)) |unlock_task|
                    unlock_task.schedule();

                return item;
            }

            var waiter: Waiter = undefined;
            waiter.task = zap.Task.init(@frame());
            waiter.item = Waiter.Item{ .none = {} };
            self.getters.push(&waiter);

            suspend {
                if (self.lock.release(&held)) |unlock_task| {
                    const thread = zap.Task.getCurrentThread();
                    if (thread.scheduleNext(unlock_task)) |old_next|
                        thread.schedule(zap.Task.Batch.from(old_next));
                }
            }

            return switch (waiter.item) {
                .some => |item| item,
                .none => unreachable,
                .closed => error.Closed,
            };
        }
    };
}