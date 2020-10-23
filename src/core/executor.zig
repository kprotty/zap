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

pub const Platform = struct {
    actionFn: fn(*Platform, ?*Worker, Action) bool,

    pub const Action = union(enum) {
        spawned: *Scheduler,
        resumed: *Worker,
        poll_first: *Task.Batch,
        poll_last: *Task.Batch,
    };

    pub fn performAction(self: *Platform, worker_scope: ?*Worker, action: Action) bool {
        return (self.actionFn)(self, worker_scope, action);
    }
};

pub const Scheduler = extern struct {
    platform: *Platform align(std.math.max(@alignOf(usize), 8)),
    active_workers: usize,
    max_workers: usize,
    run_queue: ?*Task,
    idle_queue: IdleQueue,

    pub fn init(self: *Scheduler, platform: *Platform, max_workers: usize) void {
        self.* = .{
            .platform = platform,
            .active_workers = 0,
            .max_workers = max_workers,
            .run_queue = null,
            .idle_queue = IdleQueue.init(0),
        };
    }

    pub fn deinit(self: *Scheduler) void {

    }

    pub fn push(self: *Scheduler, batch: Task.Batch) void {
        if (batch.isEmpty()) {
            return;
        }
        
        var run_queue = @atomicLoad(?*Task, &self.run_queue, .Monotonic);
        while (true) {
            batch.tail.next = run_queue;
            run_queue = @cmpxchgWeak(
                ?*Task,
                &self.run_queue,
                run_queue,
                batch.head,
                .Release,
                .Monotonic,
            ) orelse break;
        }
    }

    pub fn notify(self: *Scheduler) void {
        var idle_queue = self.idle_queue.load(.Acquire);

        while (true) {

        }
    }

    fn wait(self: *Scheduler, worker: *Worker) void {

    }

    pub fn shutdown(self: *Scheduler) void {

    }

    const IdleQueue = switch (std.builtin.arch) {
        .i386, .x86_64 => extern struct {
            value: usize align(@alignOf(DoubleWord)),
            aba_tag: usize = 0,

            const DoubleWord = std.meta.Int(.unsigned, std.meta.bitCount(usize) * 2);

            fn load(self: *const IdleQueue, comptime ordering: std.builtin.AtomicOrder) IdleQueue {
                return IdleQueue{
                    .value = @atomicLoad(usize, &self.value, ordering),
                    .aba_tag = @atomicLoad(usize, &self.value, .Unordered),
                };
            }

            fn cmpxchgWeak(
                self: *IdleQueue,
                compare: IdleQueue,
                exchange: usize,
                comptime success: std.builtin.AtomicOrder,
                comptime failure: std.builtin.AtomicOrder,
            ) ?IdleQueue {
                const value = @cmpxchgWeak(
                    DoubleWord,
                    @ptrCast(*DoubleWord, self),
                    @bitCast(DoubleWord, compare),
                    @bitCast(DoubleWord, IdleQueue{
                        .value = exchange,
                        .aba_tag = compare.aba_tag +% 1,
                    }),
                    success,
                    failure,
                ) orelse return null;
                return @bitCast(IdleQueue, value);
            }
        },
        else => extern struct {
            value: usize,

            fn load(self: *const IdleQueue, comptime ordering: std.builtin.AtomicOrder) IdleQueue {
                const value = @atomicLoad(usize, &self.value, ordering);
                return IdleQueue{ .value = value };
            }

            fn cmpxchgWeak(
                self: *IdleQueue,
                compare: IdleQueue,
                exchange: usize,
                comptime success: std.builtin.AtomicOrder,
                comptime failure: std.builtin.AtomicOrder,
            ) ?IdleQueue {
                const value = @cmpxchgWeak(
                    usize,
                    &self.value,
                    compare.value,
                    exchange,
                    success,
                    failure,
                ) orelse return null;
                return IdleQueue{ .value = value };
            }
        },
    };
};

pub const Worker = extern struct {
    id: Id align(std.math.max(@alignOf(usize), 8)),
    next: usize,
    sched_state: usize,
    runq_head: usize,
    runq_tail: usize,
    runq_next: ?*Task,
    runq_overflow: ?*Task,
    runq_buffer: [256]*Task,

    const State = enum(u2) {
        waking,
        running,
        suspended,
        shutdown,
    };

    pub const Id = *const std.meta.Int(.unsigned, 8 * std.meta.bitCount(u8));

    pub fn getId(self: *Worker) Id {
        return self.id;
    }

    pub fn getScheduler(self: *Worker) *Scheduler {
        const scheduler = 
    }

    pub const Poll = union(enum) {
        shutdown,
        suspended,
        joined: *Worker,
        executed: *Task,
    };

    pub fn poll(self: *Worker) Poll {
        var sched_state = @atomicLoad(usize, &self.sched_state, .Monotonic);
        const scheduler = @intToPtr(*Scheduler, sched_state & ~@as(usize, 0b11));
        var state = @intToEnum(State, @truncate(u2, sched_state));

        var did_inject = false;
        if (self.pollTask(scheduler, &did_inject)) |task| {

            if (state == .waking or did_inject) {
                scheduler.notifyWorker(.{ .is_waking = state == .waking });
                sched_state = @ptrToInt(scheduler) | @enumToInt(State.running);
                @atomicStore(usize, &self.sched_state, sched_state, .Monotonic);
            }

            return .{ .executed = task };
        }

        
    }

    pub fn push(self: *Worker, tasks: Task.Batch) void {

    }

    fn pollTask(self: *Worker, scheduler: *Scheduler, did_inject: *bool) ?*Task {
        var platform_tasks = Task.Batch{};
        if (scheduler.platform.performAction(self, .{ .poll_first = &platform_tasks })) {
            return platform_tasks.pop();
        }

        if (self.pollTaskLocally(did_inject)) |task| {
            return task;
        }



        if (self.pollTaskFromScheduler(scheduler, did_inject)) |task| {
            return task;
        }

        if (scheduler.platform.performAction(self, .{ .poll_last = &platform_tasks })) {
            return platform_tasks.pop();
        }

        return null;
    }
};

pub const Task = extern struct {
    next: ?*Task = undefined,
    runnable: usize,

    pub fn init(frame: anyframe) Task {
        return .{ .runnable = @ptrToInt(frame) };
    }

    pub const CallbackFn = fn(*Task, *Worker) callconv(.C) void;

    pub fn initCallback(callback: CallbackFn) Task {
        return .{ .runnable = @ptrToInt(callback) | 1 };
    }

    pub fn execute(self: *Task, worker: *Worker) void {
        if (@alignOf(CallbackFn) < 2 or @alignOf(anyframe) < 2) {
            @compileError("Architecture not supported");
        }

        if (self.runnable & 1 != 0) {
            const callback = @intToPtr(CallbackFn, self.runnable & ~@as(usize, 1));
            return (callback)(self, worker);
        }

        const frame = @intToPtr(anyframe, self.runnable);
        resume frame;
    }

    pub const Batch = struct {
        head: ?*Task = null,
        tail: *Task = undefined,

        pub fn isEmpty(self: Batch) bool {
            return self.head == null;
        }

        pub fn from(task: *Task) Batch {
            task.next = null;
            return Batch{
                .head = task,
                .tail = task,
            };
        }

        pub fn push(self: *Batch, task: *Task) void {
            return self.pushMany(Batch.from(task));
        }

        pub fn pushMany(self: *Batch, other: Batch) void {
            if (other.isEmpty())
                return;    
            if (self.isEmpty()) {
                self.* = other;
            } else {
                self.tail.next = other.head;
                self.tail = other.tail;
            }
        }

        pub fn pop(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }
    };
};



