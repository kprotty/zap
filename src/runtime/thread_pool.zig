// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const atomic = @import("../sync/atomic.zig");

const Lock = @import("./lock.zig").Lock;
const Event = @import("./event.zig").Event;
const Thread = @import("./thread.zig").Thread;

pub const ThreadPool = struct {
    counter: usize,
    stack_size: usize,
    max_threads: usize,
    pending_events: usize,
    spawned_stack: ?*Worker,
    worker_impl: *Worker.Impl,
    join_event: ?*Event,
    idle_stack: ?*Worker,
    idle_lock: Lock,

    const Self = @This();
    const Counter = struct {
        state: State = .Pending,
        is_polling: bool = false,
        is_notified: bool = false,
        idle: usize = 0,
        spawned: usize = 0,

        const count_bits = @divFloor(std.meta.bitCount(usize) - 4, 2);
        const Count = std.meta.Int(.unsigned, count_bits);
        const State = enum(u2) {
            Pending = 0,
            Waking,
            Signaled,
            Shutdown,
        };

        fn pack(self: Counter) usize {
            return ((@as(usize, @enumToInt(self.state)) << 0) |
                (@as(usize, @boolToInt(self.is_polling)) << 2) |
                (@as(usize, @boolToInt(self.is_notified)) << 3) |
                (@as(usize, @intCast(Count, self.idle)) << 4) |
                (@as(usize, @intCast(Count, self.spawned)) << (4 + count_bits)));
        }

        fn unpack(value: usize) Counter {
            return .{
                .state = @intToEnum(State, @truncate(u2, value)),
                .is_polling = value & (1 << 2) != 0,
                .is_notified = value & (1 << 3) != 0,
                .idle = @truncate(Count, value >> 4),
                .spawned = @truncate(Count, value >> (4 + count_bits)),
            };
        }
    };

    pub fn init(
        stack_size: usize,
        max_threads: usize,
        worker_impl: *Worker.Impl,
    ) Self {
        return Self{
            .counter = (Counter{}).pack(),
            .stack_size = std.math.max(std.mem.page_size, stack_size),
            .max_threads = blk: {
                const num_workers = std.math.max(1, max_threads);
                const max_threads = std.math.cast(Counter.Count, num_workers) catch std.math.maxInt(Counter.Count);
                break :blk max_threads;
            },
            .pending_events = 0,
            .spawned_workers = null,
            .worker_impl = worker_impl,
            .join_event = null,
            .idle_stack = null,
            .idle_lock = Lock{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.idle_lock.deinit();
        self.* = undefined;
    }

    pub const Worker = struct {
        pool: *Pool,
        state: State,
        thread: ?Thread,
        idle_prev: ?*Worker,
        idle_next: ?*Worker,
        spawned_next: ?*Worker,

        pub const Impl = struct {
            callFn: fn (*Impl, Action) void,

            pub const Action = union(enum) {
                RunWorker: *Worker,
                NotifyWorker: *Worker,
                SuspendWorker: *Worker,
                PollEvents: *Worker,
                SignalEvents: *Pool,
            };

            fn invoke(self: *Impl, action: Action) void {
                return (self.callFn)(self, action);
            }
        };

        const State = enum(usize) {
            Running,
            Waking,
            Searching,
            Polling,
            Waiting,
            Idle,
            Shutdown,
        };

        fn spawn(pool: *Self) bool {
            const Spawner = struct {
                thread: Thread = undefined,
                thread_pool: *Self = undefined,
                put_event: Event = .{},
                got_event: Event = .{},

                fn entry(self: *@This()) void {
                    std.debug.assert(self.put_event.wait(null));
                    const thread = self.thread;
                    const thread_pool = self.thread_pool;
                    self.got_event.set();
                    Worker.run(thread_pool, thread);
                }
            };

            var spawner = Spawner{};
            spawner.thread = Thread.spawn(&spawner, Spawner.entry) catch return false;
            spawner.thread_pool = pool;
            spawner.put_event.set();
            std.debug.assert(spawner.got_event.wait(null));

            spawner.put_event.deinit();
            spawner.got_event.deinit();
            return true;
        }

        fn run(pool: *Self, thread: ?Thread) void {
            var self = Worker{
                .pool = pool,
                .state = .waking,
                .thread = thread,
                .idle_prev = undefined,
                .idle_next = undefined,
                .spawned_next = undefined,
            };

            var spawned_stack = atomic.load(&pool.spawned_stack, .Relaxed);
            while (true) {
                self.spawned_next = spawned_stack;
                spawned_stack = atomic.tryCompareAndSwap(
                    &pool.spawned_stack,
                    spawned_stack,
                    &self,
                    .AcqRel,
                    .Relaxed,
                ) orelse break;
            }

            pool.worker_impl.invoke(.{
                .RunWorker = &self,
            });

            if (thread == null) {
                pool.join();
            } else {
                pool.worker_impl.invoke(.{ .SuspendWorker = &self });
            }
        }

        pub const SpawnedIter = struct {
            worker: ?*Worker,

            pub fn next(self: *SpawnedIter) ?*Worker {
                const worker = self.worker orelse return null;
                self.worker = worker.spawned_next;
                return worker;
            }
        };

        pub fn getPool(self: Worker) *Self {
            return self.pool;
        }

        pub fn isAlive(self: Worker) bool {
            return self.state != .shutdown;
        }

        pub const Action = enum {
            BeginWork,
            CompleteWork,
            BeginEvent,
            CompleteEvent,
        };

        pub fn do(self: *Worker, action: Action) void {
            switch (action) {
                .BeginWork => {
                    if (self.state == .waking)
                        self.getPool().notify(self);
                    self.state = .running;
                },
                .CompleteWork => {
                    self.state = .searching;
                },
                .BeginEvent => {
                    _ = atomic.fetchAdd(&self.getPool().pending_events, 1, .SeqCst);
                },
                .CompleteEvent => {
                    _ = atomic.fetchSub(&self.getPool().pending_events, 1, .SeqCst);
                },
            }
        }
    };

    pub fn getIter(self: *const Self) Worker.Iter {
        const worker_top = atomic.load(&self.spawned_stack, .Acquire);
        return .{ .worker = worker_top };
    }

    pub fn getSpawned(self: *const Self) usize {
        const counter = Counter.unpack(atomic.load(&self.counter, .Relaxed));
        return counter.spawned;
    }

    pub fn isPollable(self: *const Self) bool {
        const pending_events = atomic.load(&self.pending_events, .Relaxed);
        if (pending_events == 0)
            return false;

        const counter = Counter.unpack(atomic.load(&self.counter, .Relaxed));
        return counter.is_polling == false;
    }

    pub fn run(self: *Self) void {
        self.counter = (Counter{ .state = .Waking, .spawned = 1 }).pack();
        Worker.run(self, null);
    }

    pub fn notify(self: *Self, worker: ?*Worker) void {
        var did_spawn = false;
        var spawn_attempts: u8 = 5;
        var is_waking = if (worker) |w| w.state == .Waking else false;
        var counter = Counter.unpack(atomic.load(&self.counter, .Relaxed));

        while (true) {
            if (counter.state == .Shutdown) {
                if (did_spawn)
                    self.markShutdown();
                return;
            }

            var new_counter = counter;
            var notification: enum {
                Event,
                Update,
                Signal,
                Spawn,
            } = .Update;

            if (is_waking) {
                std.debug.assert(counter.state == .Waking);
                if (counter.is_polling or counter.idle > 0) {
                    notification = if (counter.is_polling) .Event else .Signal;
                    new_counter.state = .Signaled;
                    new_counter.is_polling = false;
                    if (did_spawn)
                        new_counter.spawned -= 1;
                } else if (spawn_attempts > 0 and (did_spawn or counter.spawned < self.max_threads)) {
                    notification = .Spawn;
                    if (!did_spawn)
                        new_counter.spawned += 1;
                } else {
                    new_counter.is_notified = true;
                    new_counter.state = .Pending;
                    if (did_spawn)
                        new_counter.spawned -= 1;
                }
            } else {
                if (counter.state == .Pending and (counter.is_polling or counter.idle > 0)) {
                    notification = if (counter.is_polling) .Event else .Signal;
                    new_counter.state = .Signaled;
                    new_counter.is_polling = false;
                } else if (counter.state == .Pending and counter.spawned < self.max_threads) {
                    notification = .Spawn;
                    new_counter.state = .Waking;
                    new_counter.spawned += 1;
                } else if (!counter.is_notified) {
                    new_counter.is_notified = true;
                } else {
                    return;
                }
            }

            if (atomic.tryCompareAndSwap(
                &self.counter,
                counter.pack(),
                new_counter.pack(),
                .Release,
                .Relaxed,
            )) |updated| {
                atomic.spinLoopHint();
                counter = Counter.unpack(updated);
                continue;
            }

            switch (notification) {
                .Update => return,
                .Signal => return self.idleWake(.One),
                .Event => return self.worker_impl.invoke(.{ .SignalEvents = self }),
                .Spawn => if (Worker.spawn(self)) return,
            }

            is_waking = true;
            did_spawn = true;
            spawn_attempts -= 1;
            Counter.unpack(atomic.load(&self.counter, .Relaxed));
        }
    }

    pub fn wait(self: *Self, worker: *Worker) void {
        std.debug.assert(worker.isAlive());
        var counter = Counter.unpack(atomic.load(&self.counter, .Relaxed));

        while (true) {
            if (counter.state == .Shutdown) {
                worker.state = .Shutdown;
                self.markShutdown();
                return;
            }

            var is_pollable = false;
            var should_update = counter.is_notified or counter.state == .Signaled or worker.state != .Waiting;
            if (!should_update) {
                is_pollable = self.isPollable();
                should_update = is_pollable;
            }

            if (should_updated) {
                var new_counter = counter;
                if (counter.state == .Signaled) {
                    new_counter.state = .Waking;
                    if (worker.state == .Waiting)
                        new_counter.idle -= 1;
                } else if (counter.is_notified) {
                    new_counter.is_notified = false;
                    if (worker.state == .Waking)
                        new_counter.state = .Waking;
                    if (worker.state == .Waiting)
                        new_counter.idle -= 1;
                } else if (is_pollable) {
                    new_counter.is_polling = true;
                    if (worker.state == .Waking)
                        new_counter.state = .Pending;
                    if (worker.state == .Waiting)
                        new_counter.idle -= 1;
                } else {
                    if (worker.state == .Waking)
                        new_counter.state = .Pending;
                    if (worker.state != .Waiting)
                        new_counter.idle += 1;
                }

                if (atomic.tryCompareAndSwap(
                    &self.counter,
                    counter.pack(),
                    new_counter.pack(),
                    .Acquire,
                    .Relaxed,
                )) |updated| {
                    atomic.spinLoopHint();
                    counter = Counter.unpack(updated);
                    continue;
                }

                if (counter.state == .Signaled) {
                    worker.state = .Waking;
                    return;
                }

                if (counter.is_notified) {
                    if (worker.state == .Waiting)
                        worker.state = .Searching;
                    return;
                }

                if (is_pollable) {
                    worker.state = .Polling;
                    self.worker_impl.invoke(.{ .PollEvents = worker });

                    worker.state = .Searching;
                    counter = Counter.unpack(switch (std.builtin.arch) {
                        .i386, .x86_64 => blk: {
                            const polling_bit = (Counter{ .is_polling = true }).pack();
                            _ = atomic.fetchAnd(&self.counter, ~polling_bit, .Relaxed);
                            break :blk atomic.load(&self.counter, .Relaxed);
                        },
                        else => blk: {
                            const polling_bit = (Counter{ .is_polling = true }).pack();
                            break :blk atomic.fetchAnd(&self.counter, ~polling_bit, .Relaxed);
                        },
                    });

                    atomic.spinLoopHint();
                    continue;
                }
            }

            worker.state = .Waiting;
            self.idleWait(worker);
            counter = Counter.unpack(atomic.load(&self.counter, .Relaxed));
        }
    }

    pub fn shutdown(self: *Self) void {
        var counter = Counter.unpack(atomic.load(&self.counter, .Relaxed));
        while (true) {
            if (counter.state == .Shutdown)
                return;

            var new_counter = counter;
            new_counter.state = .Shutdown;
            new_counter.idle = 0;
            new_counter.is_polling = false;
            if (atomic.tryCompareAndSwap(
                &self.counter,
                counter.pack(),
                new_counter.unpack(),
                .AcqRel,
                .Relaxed,
            )) |updated| {
                atomic.spinLoopHint();
                counter = Counter.unpack(updated);
                continue;
            }

            if (counter.is_polling)
                self.worker_impl.invoke(.{ .SignalEvents = self });
            if (counter.idle > 0)
                self.idleWake(.All);
            return;
        }
    }

    pub fn join(self: *Self) void {
        var join_event: Event = undefined;
        var counter = Counter.unpack(atomic.load(&self.counter, .Acquire));

        while (true) {
            std.debug.assert(counter.state == .shutdown);
            std.debug.assert(counter.idle == 0);

            if (counter.spawned == 0) {
                self.join_event = null;
                break;
            }

            if (self.join_event == null) {
                join_event = Event{};
                self.join_event = &join_event;
            }

            var new_counter = counter;
            new_counter.idle = 1;
            if (atomic.tryCompareAndSwap(
                &self.counter,
                counter.pack(),
                new_counter.pack(),
                .AcqRel,
                .Acquire,
            )) |updated| {
                atomic.spinLoopHint();
                counter = Counter.unpack(updated);
                continue;
            }

            std.debug.assert(join_event.wait(null));
            join_event.deinit();
            self.join_event = null;
            break;
        }

        var worker_iter = self.getIter();
        self.spawned_workers = null;
        while (worker_iter.next()) |worker| {
            const thread = worker.thread orelse continue;
            self.worker_impl.invoke(.{ .NotifyWorker = worker });
            thread.join();
        }
    }

    fn markShutdown(self: *Self) void {
        const one_spawned = (Counter{ .spawned = 1 }).pack();
        const counter = atomic.fetchSub(&self.counter, one_spawned, .AcqRel);

        if (counter.spawned == 1 and counter.idle == 1) {
            const join_event = self.join_event orelse unreachable;
            join_event.set();
        }
    }

    fn idleWait(self: *Self, worker: *Worker) void {
        std.debug.assert(worker.state == .Waiting);
        defer std.debug.assert(worker.state == .Waiting);

        const is_waiting = blk: {
            const held = self.idle_lock.acquire();
            defer self.idle_lock.release();

            const counter = Counter.unpack(atomic.load(&self.counter, .SeqCst));
            if (counter.is_notified or counter.state == .Signaled or counter.state == .Shutdown)
                break :blk false;

            worker.idle_prev = null;
            worker.idle_next = self.idle_stack;
            self.idle_stack = worker;
            worker.state = .Idle;
            break :blk true;
        };

        self.worker_impl.invoke(.{ .SuspendWorker = worker });

        var is_being_notified = false;
        var wait_cancelled = switch (atomic.load(&worker.state, .Relaxed)) {
            .Idle => true,
            .Waiting => false,
            else => unreachable,
        };

        if (wait_cancelled) {
            const held = self.idle_lock.acquire();
            defer held.release();

            wait_cancelled = switch (atomic.load(&worker.state, .Relaxed)) {
                .Idle => true,
                .Waiting => false,
                else => unreachable,
            };

            if (wait_cancelled) {
                worker.state = .Waiting;
                if (worker.idle_prev) |prev|
                    prev.idle_next = worker.idle_next;
                if (worker.idle_next) |next|
                    next.idle_prev = worker.idle_prev;
                if (worker == self.idle_workers)
                    self.idle_workers = null;
            } else {
                is_being_notified = true;
            }
        }

        if (is_being_notified) {
            self.worker_impl.invoke(.{ .SuspendWorker = worker });
        }
    }

    fn idleWake(self: *Self, wake_type: enum { One, All }) void {
        var workers = blk: {
            const held = self.idle_lock.acquire();
            defer self.idle_lock.release();

            const top_worker = self.idle_stack orelse return;
            var num_dequeue: usize = switch (wake_type) {
                .One => 1,
                .All => std.math.maxInt(usize),
            };

            var idle_worker = top_worker;
            while (num_dequeue > 0) : (num_dequeue -= 1) {
                const worker = idle_worker orelse break;
                idle_worker = worker.idle_next;
                std.debug.assert(worker.state == .Idle);
                atomic.store(&worker.state, .Waiting, .Relaxed);
            }

            break :blk top_worker;
        };

        while (workers) |worker| {
            workers = worker.idle_next;
            self.worker_impl.invoke(.{ .NotifyWorker = worker });
        }
    }
};
