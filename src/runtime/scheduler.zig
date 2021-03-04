// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");

const Queue = @import("./queue.zig");
const Event = @import("./event.zig").Event;
const ThreadPool = @import("./thread_pool.zig").ThreadPool;

pub const Scheduler = struct {
    thread_pool: ThreadPool,
    worker_impl: ThreadPool.WorkerImpl,
    run_queues: Priority.Array(Queue.GlobalQueue) = Priority.initArray(Queue.GlobalQueue),

    const Self = @This();

    pub const Config = struct {
        max_threads: ?usize = null,
        stack_size: ?usize = null,
    };

    pub fn init(self: *Self, config: Config) void {}

    pub fn deinit(self: *Self) void {}

    pub const Task = struct {
        node: Queue.Node = undefined,
        callback: Callback,

        pub const Callback = fn (*Worker, *Task) void;

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
        pool_worker_iter: ThreadPool.Worker.Iter = .{},
        run_next: Queue.Batch = .{},
        run_queues: Priority.Array(Queue.LocalQueue) = Priority.initArray(Queue.LocalQueue),

        pub fn getPool(self: *Worker) *Self {
            const thread_pool = self.pool_worker.getPool();
            return @fieldParentPtr(Self, "thread_pool", thread_pool);
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
            // When stealing, spin less on architectures where power consumption is important
            var steal_attempts: u8 = switch (std.builtin.arch) {
                .x86_64, .powerpc64, .powerpc64le => 8,
                else => 4,
            };

            // If we need to be fair, then we poll queues in the opposite order.
            // This is to ensure that the queues polled first don't starve the queues normally polled last.
            if (be_fair) {
                steal_attempts -= 1;
                if (self.pollSteal(be_fair)) |node|
                    return node;

                if (self.pollLocal(be_fair)) |node|
                    return node;

                if (self.pollTimer(null)) |node|
                    return node;
            } else {
                if (self.pollTimer(null)) |node|
                    return node;

                if (self.pollLocal(be_fair)) |node|
                    return node;
            }

            // If we couldn't find any work with the normal means,
            // then we try to steal work from others a few times before giving up.
            while (steal_attempts > 0) : (steal_attempts -= 1) {
                if (self.pollSteal(be_fair)) |node|
                    return node;
            }

            return null;
        }

        fn pollLocal(self: *Worker, be_fair: bool) callconv(.Inline) ?*Queue.Node {
            return self.pollQueues(self, be_fair);
        }

        fn pollSteal(self: *Worker, be_fair: bool) ?*Queue.Node {
            // When stealing, check for events before remote queues if we need to be fair.
            // This prevents the remote queues from starving the processing of the events.
            if (be_fair) {
                if (self.pollEvents()) |node|
                    return node;
            }

            // Check the pool run queues first as its best to get external work into the local queues.
            const pool = self.getPool();
            if (self.pollQueues(&pool.run_queues, be_fair)) |node|
                return node;

            // Then, iterate the other Workers and try to steal from their run queues
            var iter = pool.thread_pool.getSpawned();
            steal: while (iter > 0) : (iter -= 1) {
                const target_pool_worker = self.pool_worker_iter.next() orelse blk: {
                    self.pool_worker_iter = pool.thread_pool.getIter();
                    break :blk (self.pool_worker_iter.next() orelse break :steal);
                };

                const target_worker = @fieldParentPtr(Worker, "pool_worker", target_pool_worker);
                if (target_worker == self)
                    continue;

                if (self.pollQueues(&target_worker.run_queues, be_fair)) |node|
                    return node;
            }

            // Finally, check if theres any events to process since theres no work in the pool.
            if (self.pollEvents()) |node|
                return node;

            return null;
        }

        fn pollQueues(self: *Worker, queues: anytype, be_fair: bool) ?*Queue.Node {
            // Reverse the priority order if we need to be fair
            // as it allows higher priorities to not starve the lower ones.
            var priority_order = [_]Priority{ .Handoff, .High, .Normal, .Low };
            if (be_fair) {
                priority_order = [_]Priority{ .Low, .Normal, .High, .Handoff };
            }

            for (priority_order) |priority| {
                const priority_index = priority.toArrayIndex();
                const local_queue = &self.run_queues[priority_index];

                // If its not a local poll, then use popAndSteal()
                if (@TypeOf(queues) != @TypeOf(self)) {
                    const target_queue = &queues[priority_index];
                    return local_queue.popAndSteal(target_queue, be_fair) orelse continue;
                }

                // Handoff priority tasks go into the run_next queue
                if (priority == .Handoff) {
                    return self.run_next.pop() orelse continue;
                }

                // Otherwise, its a local poll
                if (local_queue.pop(be_fair)) |node|
                    return node;
            }

            return null;
        }

        fn pollTimer(self: *Worker, next_expiry: ?*u64) ?*Queue.Node {
            @compileError("TODO");
        }

        fn pollEvents(self: *Worker) ?*Queue.Node {
            @compileError("TODO");
        }
    };
};
