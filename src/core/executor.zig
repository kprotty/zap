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
    actionFn: fn(*Platform, ?*Worker, Action) void,

    pub const Action = union(enum) {
        spawned: *Scheduler,
        resumed: *Worker,
        poll_first: *Task.Batch,
        poll_last: *Task.Batch,
    };

    pub fn performAction(self: *Platform, worker_scope: ?*Worker, action: Action) void {
        return (self.actionFn)(self, worker_scope, action);
    }
};

pub const Scheduler = extern struct {
    platform: *Platform align(std.math.max(@alignOf(usize), 8)),
    active_queue: ?*Worker,
    active_workers: usize,
    max_workers: usize,
    run_queue: ?*Task,
    idle_queue: IdleQueue,

    const IdleState = enum(u2) {
        pending,
        waking,
        notified,
        shutdown,
    };

    pub fn init(self: *Scheduler, platform: *Platform, max_workers: usize) void {
        self.* = .{
            .platform = platform,
            .active_queue = null,
            .active_workers = 0,
            .max_workers = max_workers,
            .run_queue = null,
            .idle_queue = IdleQueue.init(@enumToInt(IdleState.pending)),
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
        self.resumeWorker(.{});
    }

    const ResumeContext = struct {
        is_waking: bool = false,
        worker: ?*Worker = null,   
    };

    fn resumeWorker(self: *Scheduler, context: ResumeContext) void {
        var is_waking = false;
        var is_resuming = false;
        var idle_queue = self.idle_queue.load(.Acquire);

        while (true) {
            const idle_state = @intToEnum(IdleState, @truncate(u2, idle_queue.value);
            if (idle_state == .shutdown) {
                return;
            }

            if (context.is_waking and idle_state != .waking) {
                unreachable; // resumeWorker(is_waking) when idle_queue is not marked as such
            }

            if (!context.is_waking and idle_state == .waking) {
                idle_queue = self.idle_queue.cmpxchgWeak(
                    idle_queue,
                    (idle_queue.value & ~@as(usize, 0b11)) | @enumtToInt(IdleState.notified),
                    .Acquire,
                    .Acquire,
                ) orelse return;
                continue;
            }

            if (!context.is_waking and idle_state == .notified) {
                return;
            }

            if (@intToPtr(?*Worker, idle_queue.value & ~@as(usize, 0b11))) |idle_worker| {
                const next_worker = @atomicLoad(usize, &idle_worker.state, .Unordered) & ~@as(usize, 0b11);
                if (self.idle_queue.cmpxchgWeak(
                    idle_queue,
                    next_worker | @enumToInt(IdleState.waking),
                    .Acquire,
                    .Acquire,
                )) |updated_idle_queue| {
                    idle_queue = updated_idle_queue;
                    continue;
                }

                const new_state = @ptrToInt(self) | @enumToInt(Worker.State.waking);
                @atomicStore(usize, &idle_worker.state, new_state, .Unordered);
                self.platform.performAction(context.worker, .{ .resumed = idle_worker });
                return;
            }

            const active_workers = @atomicLoad(usize, &self.active_workers, .Monotonic);
            if (active_workers < self.max_workers) {
                if (!context.is_waking) {
                    if (self.idle_queue.cmpxchgWeak(
                        idle_queue,
                        @enumToInt(IdleState.waking),
                        .Acquire,
                        .Acquire,
                    )) |updated_idle_queue| {
                        idle_queue = updated_idle_queue;
                        continue;
                    } 
                }

                _ = @atomicRmw(usize, &self.active_workers, .Add, 1, .Monotonic);
                self.platform.performAction(context.worker, .{ .spawned = self });
                return;
            }

            if (context.is_waking) {
                idle_queue = self.idle_queue.cmpxchgWeak(
                    idle_queue,
                    @enumToInt(IdleState.pending),
                    .Acquire,
                    .Acquire,
                ) orelse return;
                continue;
            }

            return;
        }
    }

    fn suspendWorker(self: *Scheduler, worker: *Worker) void {

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
    id: ?Id align(std.math.max(@alignOf(Id), 8)),
    state: usize,
    target: ?*Worker,
    active_next: ?*Worker,
    runq_head: u8,
    runq_tail: u8,
    runq_next: ?*Task,
    runq_overflow: ?*Task,
    runq_buffer: [256]*Task,

    const State = enum(u2) {
        waking,
        running,
        suspended,
        shutdown,
    };

    pub const Id = *align(8) c_void;

    pub fn init(self: *Worker, scheduler: *Scheduler, id: ?Id) void {
        self.* = Worker{
            .id = id,
            .state = @ptrToInt(scheduler) | @enumToInt(State.waking),
            .active_next = undefined,
            .runq_head = 0,
            .runq_tail = 0,
            .runq_next = null,
            .runq_buffer = undefined,
        };

        var active_queue = @atomicLoad(?*Task, &scheduler.active_queue, .Monotonic);
        while (true) {
            self.active_next = active_queue;
            active_queue = @cmpxchgWeak(
                ?*Task,
                &scheduler.active_queue,
                active_queue,
                self,
                .Release,
                .Monotonic,
            ) orelse break;
        }
    }

    pub fn deinit(self: *Worker) void {
        const scheduler = self.getScheduler();
        _ = @atomicRmw(usize, &scheduler.active_workers, .Sub, 1, .Monotonic);
    }

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

        if (scheduler.suspendWorker(self)) {
            return .suspended;
        }

        // TODO: scheduler.shutdownWorker(self); - join if main/master_worker
        return .shutdown;
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

        // TODO: work-stealing by iterating active_head -> active_next

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

        // TODO: add more functionality
    };
};



