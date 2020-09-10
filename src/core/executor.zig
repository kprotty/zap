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
const TimingWheel = zap.core.Timer.Wheel;

pub fn Executor(comptime Platform: type) type {
    return struct {
        pub const Event = union(enum) {
            thread_started: *Thread,
            thread_stopped: *Thread,
            task_suspend: TaskContext,
            task_resumed: TaskContext,

            pub const TaskContext = struct {
                task: *Task,
                thread: *Thread,
            };

            pub fn emit(self: Event) void {
                Platform.onEvent(self);
            }
        };

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

                        const Waiting = extern struct {
                            has_entry: bool,
                            entry: Thread.Timer.Entry,
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

                    fn timedOut(task: *Task, thread: *Thread) callconv(.C) void {
                        const entry = 
                    }

                    fn notify(self: *Future, thread: *Thread) void {
                        // if from signal:
                            // transtion waiting -> notified=0
                                // if timeout running and failed to cancel it:
                                    // transition notified=0 -> notified=task (from waiting)
                                        // return as timedOut will wake up task
                                    // notified=1
                                        // fallthrough
                                // wake up task (from waiting)
                            // cancelled ? -> nothing
                        // if from timedOut:
                            // transition waiting -> cancelled
                                // schedule task from waiting state
                            // notified ? -> 
                                // transition notified=task|0 -> notified=1:
                                    // if notified task: schedule task from notified state
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
                                        thread.scheduleAfter(&waiting_ptr.entry, timeout_task, timeout);
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
                                        if (!thread.cancelScheduleAfter(&waiting_ptr.entry))
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
            data: Platform.Thread.Data,
            timer: 

            var current: Platform.Thread.Local = Platform.Thread.Local{};

            pub fn run(
                worker: *Worker,
                handle: ?core.Thread.Handle.Ptr,
                data: Platform.Thread.Data,
            ) void {
                var self = Thread{
                    .inner = undefined,
                    .data = data,
                };
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

            fn notify(self: *Thread) void {

            }
        };

        pub const Worker = core.Worker;

        pub const Node = extern struct {
            inner: core.Node,
            data: Platform.Node.Data,

            pub fn schedule(self: *Node, batch: Batch) void {
                self.inner.push(batch.inner);
                self.resumeThread();
            }

            pub fn scheduleLocally(self: *Node, batch: Batch) void {
                self.inner.pushLocal(batch.inner);
                if (self.inner.tryResumeLocalThread()) |schedule|
                    self.wake(schedule);
            }

            fn resumeThread(self: *Node) void {
                if (self.inner.tryResumeThread()) |schedule|
                    self.wake(schedule);
            }
        };
    };
}
