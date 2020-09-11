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

const core = zap.core.TaskScheduler;
const Atomic = zap.core.sync.Atomic;

pub fn Executor(comptime Platform: type) type {
    const os = struct {
        const Node = struct {
            const Data = Platform.Node.Data;
        };

        const Thread = struct {
            const Handle = core.Thread.Handle.Ptr;
            const Local = Platform.Thread.Local;
            const Signal = Platform.Thread.Signal;
        };
    };

    return struct {
        pub const Task = extern struct {
            inner: core.Task,

            pub const Callback = fn(*Task, *Thread) callconv(.C) void;

            pub fn fromFrame(frame: anyframe) Task {
                return Task{ .inner = core.Task.fromFrame(frame) };
            }

            pub fn fromCallback(callback: Callback) Task {
                return Task{ .inner = core.Task.fromCallback(callback) };
            }

            pub fn execute(self: *Task, thread: *Thread) void {
                return self.inner.execute(&thread.inner);
            }

            pub const Batch = struct {
                inner: core.Task.Batch = core.Task.Batch{},

                pub fn isEmpty(self: Batch) bool {
                    return self.inner.isEmpty();
                }

                pub fn from(task: ?*Task) Batch {
                    return Batch{ .inner = core.Task.Batch.from(&task.inner) };
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
                    return self.inner.pushBackMany(other.inner);
                }

                pub fn pushFrontMany(self: *Batch, other: Batch) void {
                    return self.inner.pushFrontMany(other.inner);
                }

                pub fn pop(self: *Batch) ?*Task {
                    return self.popFront();
                }

                pub fn popFront(self: *Batch) ?*Task {
                    const inner = self.inner.popFront() orelse return null;
                    return @fieldParentPtr(Task, "inner", inner);
                }

                pub fn schedule(self: Batch) void {
                    const thread = Thread.getCurrent();
                    thread.schedule(self);
                }

                pub fn scheduleLocally(self: Batch) void {
                    const thread = Thread.getCurrent();
                    thread.scheduleLocally(self);
                }
            };

            pub const AsyncSignal = extern struct {
                const Self = @This();

                inner: Signal = Signal{},

                pub fn notify(self: *Self) void {
                    return self.inner.notify(Thread.getCurrent());
                }

                pub const INFINITE = Signal.INFINITE;

                pub fn wait(self: *Self) void {
                    self.timedWait(INFINITE) catch unreachable;
                }

                pub fn timedWait(self: *Self, timeout: u64) error{TimedOut}!void {
                    var result: ?bool = null;
                    var future = self.inner.timedWait(timeout);
                    
                    suspend {
                        const thread = Thread.getCurrent();
                        var task = Task.fromFrame(@frame());

                        result = switch (future.poll(Signal.Future.Context{
                            .task = &task,
                            .thread = thread,
                        })) {
                            .pending => null,
                            .ready => |notified| notified,
                        };

                        if (result != null) {
                            thread.scheduleNext(&task);
                        }
                    }

                    const notified = result orelse future.poll(undefined).ready;
                    if (!notified)
                        return error.TimedOut;
                }
            };

            pub const Signal = extern struct {
                const EMPTY: usize = 0;
                const NOTIFIED: usize = 1;

                state: usize = EMPTY,

                pub fn notify(self: *Signal, thread: *Thread) void {
                    const state = Atomic.update(&self.state, .swap, NOTIFIED, .acq_rel);
                    if (state > NOTIFIED)
                        notifySlow(thread, state);
                }

                fn notifySlow(thread: *Thread, state: usize) void {
                    @setCold(true);

                    const future = blk: {
                        @setRuntimeSafety(false);
                        @intToPtr(*Future, state);
                    };

                    future.notify(thread);
                }

                pub const INFINITE = std.math.maxInt(u64);

                pub fn wait(self: *Signal) Future {
                    return self.timedWait(INFINITE);
                }

                pub fn timedWait(self: *Signal, timeout: u64) Future {
                    return Future.init(self, timeout);
                }

                pub const Future = extern struct {
                    pub const Poll = union(enum) {
                        pending: void,
                        ready: bool,
                    };

                    pub const Context = struct {
                        task: *Task,
                        thread: *Thread,
                    };

                    const State = enum(u2) {
                        init,
                        waiting,
                        cancelled,
                        notified,

                        fn toUsize(self: State, payload: usize) usize {
                            return payload | @enumToInt(self);
                        }

                        fn getPayload(value: usize) usize {
                           return value & ~@as(usize, ~@as(@TagType(State), 0)); 
                        }

                        fn get(value: usize) State {
                            return @intToEnum(State, @truncae(@TagType(State), value));
                        }
                    };

                    const Data = extern union {
                        init: Init,
                        waiting: Waiting,

                        const Init = extern struct {
                            signal: *Signal,
                            timeout: u64,
                        };

                        const Entry = Thread.Timer.Entry;
                        const Waiting = extern struct {
                            has_entry: bool,
                            entry: Entry,
                        };
                    };

                    state: usize align(std.math.max(4, std.meta.alignment(usize))),
                    data: Data,

                    fn init(signal: *Signal, timeout: u64) Future {
                        return Future{
                            .state = State.init.toUsize(0),
                            .data = Data{
                                .init = Data.Init{
                                    .signal = signal,
                                    .timeout = timeout,
                                },
                            },
                        };
                    }

                    fn notify(self: *Future, thread: *Thread) void {
                        var task: *Task = undefined;
                        var state = Atomic.load(&self.state, .relaxed);

                        while (true) {
                            switch (State.get(state)) {
                                .init => unreachable,
                                .notified => unreachable,
                                .cancelled => return,
                                .waiting => {
                                    task = @intToPtr(*Task, State.getPayload(state));
                                    state = Atomic.compareAndSwap(
                                        .weak,
                                        state,
                                        State.notified.toUsize(0),
                                        .acquire,
                                        .relaxed,
                                    ) orelse break;
                                },
                            }
                        }

                        const waiter_ptr = &self.data.waiter;
                        if (waiter_ptr.has_entry and !thread.timer.cancelScheduleAfter(waiter_ptr)) {
                            state = Atomic.load(&self.state, .relaxed);
                            while (true) {
                                switch (State.get(state)) {
                                    .init => unreachable,
                                    .waiting => unreachable,
                                    .cancelled => unreachable,
                                    .notified => {
                                        if (State.getPayload(state) != 0)
                                            break;
                                        state = Atomic.compareAndSwap(
                                            .weak,
                                            state,
                                            State.notified.toUsize(@ptrToInt(task)),
                                            .release,
                                            .relaxed,
                                        ) orelse return;
                                    },
                                }
                            }
                        }

                        thread.schedule(Task.Batch.from(task));
                    }

                    fn timedOut(task: *Task, thread: *Thread) callconv(.C) void {
                        const entry = Data.Entry.fromTask(task);
                        const waiting_ptr = @fieldParentPtr(Data.Waiting, "entry", entry);
                        const data_ptr = @ptrCast(*Data, waiting_ptr);
                        const self = @fieldParentPtr(Future, "data", data_ptr);
                        
                        var waiter_task: ?*Task = null;
                        var state = Atomic.load(&self.state, .relaxed);

                        while (true) {
                            switch (State.get(state)) {
                                .init => unreachable,
                                .cancelled => unreachable,
                                .notified => break,
                                .waiting => {
                                    state = Atomic.compareAndSwap(
                                        .weak,
                                        state,
                                        State.cancelled.toUsize(0),
                                        .acquire,
                                        .relaxed,
                                    ) orelse {
                                        @setRuntimeSafety(false);
                                        waiter_task = @intToPtr(*Task, State.getPayload(state));
                                        break;
                                    };
                                }
                            }
                        }

                        const task = waiter_task orelse blk: {
                            while (true) {
                                switch (State.get(state)) {
                                    .init => unreachable,
                                    .waiting => unreachable,
                                    .cancelled => unreachable,
                                    .notified => {
                                        state = Atomic.compareAndSwap(
                                            .weak,
                                            state,
                                            State.notified.toUsize(1),
                                            .acquire,
                                            .relaxed,
                                        ) orelse {
                                            waiter_task = @intToPtr(?*Task, State.getPayload(state));
                                            break :blk waiter_task orelse return;
                                        };
                                    },
                                }
                            }
                        };

                        thread.scheduleNext(task);                 
                    }

                    pub fn poll(self: *Future, context: Context) Poll {
                        const task = context.task;
                        const thread = context.thread;
                        var state = Atomic.load(&self.state, .relaxed);
                        
                        while (true) {
                            switch (State.get(state)) {
                                .init => {
                                    const init_ptr = &self.data.init;
                                    const signal = init_ptr.signal;
                                    const timeout = init_ptr.timeout;

                                    Atomic.compilerFence(.SeqCst);

                                    const waiting_ptr = &self.data.waiting;
                                    waiting_ptr.has_entry = timeout < INFINITE;
                                    if (waiting_ptr.has_entry) {
                                        const timeout_task = Task.fromCallback(Future.timedOut);
                                        thread.timer.scheduleAfter(&waiting_ptr.entry, timeout_task, timeout);
                                    }

                                    self.state = State.waiting.toUsize(@ptrToInt(task));
                                    const signal_state = Atomic.compareAndSwap(
                                        .strong,
                                        &signal.state,
                                        EMPTY,
                                        @ptrToInt(self),
                                        .release,
                                        .acquire,
                                    ) orelse return Poll{ .pending = {} };

                                    if (waiting_ptr.has_entry) {
                                        if (!thread.timer.cancelScheduleAfter(&waiting_ptr.entry))
                                            std.debug.panic("timer already expired while thread is running", .{});
                                    }

                                    state = State.notified;
                                    self.state = state.toUsize(0);
                                    continue;
                                },
                                .waiting => {
                                    state = Atomic.compareAndSwap(
                                        .weak,
                                        &self.state,
                                        state,
                                        State.waiting.toUsize(@ptrToInt(task)),
                                        .release,
                                        .relaxed,
                                    ) orelse return Poll{ .pending = {} };
                                },
                                .cancelled => {
                                    return Poll{ .ready = false };
                                },
                                .notified => {
                                    return Poll{ .ready = true };
                                },
                            }
                        }
                    } 
                };
            };

            pub fn run(self: *Task, nodes: Node.Cluster, start_node: *Node) !void {
                
            }
        };

        pub const Thread = extern struct {
            inner: core.Thread,
            next_task: ?*Task,
            data: OsThreadData,
            timer: Timer,
            prng: RandGen,

            const RandGen = extern struct {
                state: u64,
                random: std.rand.Random,

                fn init(seed: u64) RandGen {
                    return RandGen{
                        .state = seed,
                        .random = std.rand.Random{ .fillFn = fill },
                    };
                }

                fn fill(random: *std.rand.Random, buffer: []u8) void {
                    var i: usize = 0;
                    while (i < buffer.len) {
                        self.state ^= self.state << 13;
                        self.state ^= self.state >> 7;
                        self.state ^= self.state << 17;
                        const chunk = @bitCast([@sizeOf(u64)]u8, self.state);
                        const size = std.math.min(buffer.len - i, chunk.len);
                        @memcpy(buffer[0..].ptr, chunk[0..].ptr, size);
                        i += size;
                    }
                }
            };

            const Timer = extern struct {
                const resolution = std.time.ns_per_ms;
                const Wheel = zap.core.Timer.Wheel(6, 8);
                const Entry = extern struct {
                    inner: Wheel.Entry,
                    task: Task,
                };

                lock: os.Thread.Lock,
                wheel: Wheel,
                active: usize,
                started: u64,

                fn init(self: *Timer) void {
                    self.lock.init();
                    self.wheel = Wheel{};
                    self.active = 0;

                    const thread = @fieldParentPtr(Thread, "timer", self);
                    self.started = os.Thread.nanotime(&thread.data, thread.getHandle());
                }

                fn deinit(self: *Timer) void {
                    self.lock.deinit();
                    if (self.active != 0)
                        std.debug.panic("Timer.deinit() with pending tasks", .{});
                }

                fn scheduleAfter(self: *Timer, entry: *Entry, task: Task, delay_ns: u64) void {
                    self.lock.acquire();
                    defer self.lock.release();

                    entry.task = task;
                    self.wheel.add(&entry.inner, delay_ns / resolution);
                    self.active += 1;
                }
                
                fn cancelScheduleAfter(self: *Timer, entry: *Entry) bool {
                    self.lock.acquire();
                    defer self.lock.release();

                    if (self.wheel.tryRemove(&entry.inner)) {
                        Atomic.store(&self.active, self.active - 1, .unordered);
                        return true;
                    }

                    return false;
                }

                const Poll = struct {
                    wait_for: u64 = 0,
                    expired: Batch = Batch{},
                };

                fn poll(self; *Timer) ?Poll {
                    if (Atomic.load(&self.active, .unordered) == 0)
                        return null;

                    self.lock.acquire();
                    defer self.lock.release();

                    if (self.active == 0)
                        std.debug.panic("polled timer when no active tasks were found\n", .{});

                    const thread = @fieldParentPtr(Thread, "timer", self);
                    const now = os.Thread.nanotime(&thread.data, thread.getHandle());
                    self.wheel.advance(now -% self.started);

                    var poll_result = Poll{};
                    while (self.wheel.poll()) |polled| {
                        switch (polled) {
                            .wait_for => {
                                poll_result.wait_for = wait_for * resolution;
                                break;
                            },
                            .expired => |inner_entry| {
                                const entry = @fieldParentPtr(Entry, "inner", inner_entry);
                                poll_result.expired.push(&entry.task);
                                self.active -= 1;
                            },
                        }
                    }

                    return poll_result;
                }
            };

            var current: OsThreadLocal = OsThreadLocal{};

            pub fn run(
                parameter: usize,
                handle: ?OsThreadHandle,
                data: OsThreadData,
            ) void {
                const worker = @intToPtr(*Worker, parameter);
                var self = Thread{
                    .inner = undefined,
                    .data = data,
                    .timer = undefined,
                    .prng = RandGen.init(parameter),
                };

                self.timer.init();
                defer self.timer.deinit();

                self.inner.init(worker, handle);
                defer self.inner.deinit();

                const old_current = current.get();
                current.set(@ptrToInt(&self));
                defer current.set(old_current);

                while (true) {
                    while (self.poll()) |task| {
                        task.execute(self);
                    }
                }
            }

            fn poll(self: *Thread) ?*Task {
                if (self.next_task) |next_task| {
                    const task = next_task;
                    self.next_task = null;
                    return task;
                }

                var next_timeout: ?u64 = null;
                if (self.timer.poll()) |polled| {
                    next_timeout = polled.wait_for;
                    var batch = polled.batch;
                    if (batch.pop()) |task| {
                        self.schedule(batch);
                        return task;
                    }
                }

                const polled = self.inner.poll(&self.prng.random);
                if (polled.schedule) |scheduled|
                    Node.wake(scheduled);
                if (polled.task) |task|
                    return task;

                return null;
            }

            pub fn getCurrent() *Thread {
                const ptr = Thread.current.get();
                if (ptr == 0)
                    std.debug.panic("Thread.getCurrent() when not running inside task executor", .{});
                
                @setRuntimeSafety(false);
                return @intToPtr(*Thread, ptr);
            }
           
            pub fn getNode(self: *Thread) *Node {
                return @fieldParentPtr(Node, "inner", self.inner.getNode());
            }

            pub fn schedule(self: *Thread, batch: Batch) void {
                self.inner.push(batch.inner);
                self.getNode().resumeThread();
            }

            pub fn scheduleLocally(self: *Thread, batch: Batch) void {
                self.inner.pushLocal(batch.inner);
                self.notify();
            }

            pub fn scheduleNext(self: *Thread, task: *Task) void {
                if (self.next_task) |old_next|
                    self.schedule(Batch.from(old_next));
                self.next_task = task;
            }

            fn notify(self: *Thread) void {

            }
        };

        pub const Worker = core.Worker;

        pub const Node = extern struct {
            inner: core.Node,
            data: OsNodeData,

            pub fn schedule(self: *Node, batch: Batch) void {
                self.inner.push(batch.inner);
                self.resumeThread();
            }

            pub fn scheduleLocally(self: *Node, batch: Batch) void {
                self.inner.pushLocal(batch.inner);
                if (self.inner.tryResumeLocalThread()) |schedule|
                    wake(schedule);
            }

            fn resumeThread(self: *Node) void {
                if (self.inner.tryResumeThread()) |schedule|
                    wake(schedule);
            }

            fn wake(schedule: core.Node.Schedule) void {
                const node = schedule.getNode();
                switch (schedule.getResult()) {
                    .notified => {},
                    .resumed => |inner_thread| {
                        const thread = @fieldParentPtr(Thread, "inner", inner_thread);
                        thread.notify();
                    },
                    .spawned => |worker| {
                        if (!os.Thread.spawn(
                            &node.data,
                            @ptrToInt(worker),
                            Thread.run,
                        )) {
                            schedule.undo();
                        }
                    },
                }
            }
        };
    };
}
