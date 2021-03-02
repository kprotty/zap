// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");

const Queue = @import("./queue.zig");
const Event = @import("./event.zig").Event;
const ThreadPool = @import("./thread_pool.zig").ThreadPool

pub const Scheduler = struct {
    pool: ThreadPool,
    worker_impl: ThreadPool.WorkerImpl,
    run_queues: Priority.Array(Queue.GlobalQueue) = Priority.initArray(Queue.GlobalQueue),

    const Self = @This();

    pub const Config = struct {
        max_threads: ?usize = null,
        stack_size: ?usize = null,
    };

    pub fn init(self: *Self, config: Config) void {

    }

    pub fn deinit(self: *Self) void {

    }

    pub const Task = struct {
        node: Queue.Node = undefined,
        callback: Callback,

        pub const Callback = fn(*Worker, *Task) void;

        pub fn from(callback: Callback) Task {
            return .{ .callback = callback };
        }
    };

    pub const Priority = enum(u2) {
        Low = 0,
        Normal = 1,
        High = 2,
        Handoff = 3,

        fn Array(comptime T: type) type {
            return [3]T;
        }

        fn initArray(comptime T: type) Array(T) {
            return [_]T{.{}} ** 3;
        }

        fn toArrayIndex(self: Priority) usize {
            return switch (self) {
                .Handoff, .High => 0,
                .Normal => 1,
                .Low => 2,
            };
        }
    };

    pub fn schedule(self: *Self, task: *Task, priority: Priority) void {
        const priority_index = priority.toArrayIndex();
        const run_queue = &self.run_queues[priority_index];
        run_queue.push(Queue.Batch.from(&task.node));
        self.pool.notify(null);
    }

    pub const Worker = struct {
        pool_worker: *ThreadPool.Worker,
        run_next: Queue.Batch = .{},
        run_queues: Priority.Array(Queue.LocalQueue) = Priority.initArray(Queue.LocalQueue),
        
        pub fn getPool(self: *Worker) *Self {
            const thread_pool = self.pool_worker.getPool();
            return @fieldParentPtr(Self, "pool", thread_pool);
        }

        pub fn schedule(self: *Worker, task: *Task, priority: Priority) void {
            if (priority == .Handoff) {
                self.run_next.push(Queue.Batch.from(&task.node));
                return;
            }

            const priority_index = priority.toArrayIndex();
            const run_queue = &self.run_queues[priority_index];
            run_queue.push(Queue.Batch.from(&task.node));

            const thread_pool = self.pool_worker.getPool();
            thread_pool.notify(self.pool_worker);
        }

        fn poll(self: *Worker, be_fair: bool) ?*Queue.Node {
            if (be_fair) {
                if (self.pollRemote(be_fair)) |node|
                    return node;
            }

            if (self.pollLocal(be_fair)) |node|
                return node;

            var steal_attempts: u8 = 8;
            while (steal_attempts > 0) : (steal_attempts -= 1) {
                if (self.pollRemote(be_fair)) |node|
                    return node;
            }

            return null;
        }

        fn pollLocal(self: *Worker, be_fair: bool) ?*Queue.Node {
            if (be_fair) {
                if (self.pollEvents()) |node|
                    return node;

                if (self.pollTimer()) |node|
                    return node;
            }

            var priority_order = [_]Priority{ .Handoff, .High, .Normal, .Low };
            if (be_fair) {
                priority_order = [_]Priority{ .Low, .Normal, .High, .Handoff };
            }

            for (priority_order) |priority| {
                if (switch (priority) {
                    .Handoff => self.run_next.pop(),
                    else => self.run_queues[priority.toArrayIndex()].pop(be_fair),
                }) |node| {
                    return node;
                }
            }

            if (!be_fair) {
                if (self.pollTimer()) |node|
                    return node;

                if (self.pollEvents()) |node|
                    return node;
            }
            
            return null;
        }

        fn pollRemote(self: *Worker, be_fair: bool) ?*Queue.Node {
            
        }

        fn pollTimer(self: *Worker) |node| {
            
        }

        fn pollEvents(self: *Worker) ?*Queue.Node {
            
        }
    };
};