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
        spawned: *Worker.Slot,
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
    slots_ptr: [*]Worker.Slot,
    slots_len: usize,
    run_queue: ?*Task,
    idle_queue: usize, // [aba_tag:..., [is_shutdown:1, is_waking:1, is_notified:1, is_empty:1, worker_index:12(4096)]:16]

    pub fn init(self: *Scheduler, platform: *Platform, worker_slots: []Worker.Slot) void {
        const num_slots = std.math.min(Worker.Slot.max, worker_slots.len);

        for (worker_slots[0..num_slots]) |*slot, index| {
            const next_index = if (index == 0) null else index;
            slot.ptr = (Worker.Slot.Ptr{ .idle = next_index }).toUsize();
        }

        self.* = .{
            .platform = platform,
            .slots_ptr = worker_slots.ptr,
            .slots_len = num_slots,
            .run_queue = null,
            .idle_queue = num_slots - 1,
        };
    }

    pub fn deinit(self: *Scheduler) void {

    }

    pub fn getSlots(self: *Scheduler) []Worker.Slot {

    }

    pub fn push(self: *Scheduler, tasks: Task.Batch) void {

    }

    pub fn notify(self: *Scheduler) void {

    }

    pub fn shutdown(self: *Scheduler) void {

    }
};

pub const Worker = extern struct {
    sched_state: usize align(std.math.max(@alignOf(usize), 8)),
    id: Id,
    prng: u32,
    slot: u16,
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

    pub const Id = *const std.meta.Int(.unsigned, 8 * std.meta.bitCount(u8));

    pub fn getId(self: *Worker) Id {
        return self.id;
    }

    pub fn getScheduler(self: *Worker) *Scheduler {

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

        const slots = scheduler.getSlots();
        const self_index = self.slot_index;
        
        var steal_attempts: u8 = 1;
        while (steal_attempts > 0) : (steal_attempts -= 1) {
            
            var slot_index = blk: {
                var x = self.prng;
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                self.prng = x;
                break :blk (x % slots.len);
            };

            var slot_iter = slots.len;
            while (slot_iter > 0) : (slot_iter -= 1) {
                const target_index = slot_index;
                slot_index = if (index == slots.len - 1) 0 else (slot_index + 1);

                if (target_index == self_index) {
                    continue;
                }

                const slot_value = @atomicLoad(usize, &slots[slot_index].ptr, .Acquire);
                switch (Slot.Ptr.fromUsize(slot_value)) {
                    .idle => {},
                    .spawning => {},
                    .shutdown => return null,
                    .running => |worker| {
                        if (self.pollTaskFromWorker(worker, did_inject)) |task| {
                            return task;
                        }
                    },
                }
            }
        }

        if (self.pollTaskFromScheduler(scheduler, did_inject)) |task| {
            return task;
        }

        if (scheduler.platform.performAction(self, .{ .poll_last = &platform_tasks })) {
            return platform_tasks.pop();
        }

        return null;
    }

    pub const Slot = extern struct {
        ptr: usize,

        pub const max = 1 << 12;

        const Ptr = union(enum) {
            idle: ?usize,
            running: *Worker,
            spawning: *Scheduler,
            shutdown: ?Id,

            fn fromUsize(value: usize) Ptr {
                return switch (value & 0b11) {
                    0 => Ptr{ .idle = if (value & (1 << 2) != 0) null else (value >> 3) },
                    1 => Ptr{ .running = @intToPtr(*Worker, value >> 2) },
                    2 => Ptr{ .spawning = @intToPtr(*Scheduler, value >> 2) },
                    3 => Ptr{ .shutdown = @intToPtr(?Id, value >> 2) },
                };
            }
            
            fn toUsize(self: Ptr) usize {
                return switch (self) {
                    .idle => |next_index| (if (next_index) |i| (i << (bits + 1)) else (1 << bits)) | 0,
                    .running => |worker| @ptrToInt(worker) | 1,
                    .spawning => |scheduler| @ptrToInt(scheduler) | 2,
                    .shutdown => |id| @ptrToInt(id) | 3,
                };
            }
        };
    };
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



