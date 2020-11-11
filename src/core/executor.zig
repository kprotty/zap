// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const core = @import("./core.zig");

const atomic = core.sync.atomic;
const Atomic = atomic.Atomic;
const Ordering = atomic.Ordering;
const spinLoopHint = atomic.spinLoopHint;

pub const Task = struct {
    next: ?*Task = undefined,
};

pub const Batch = struct {

};

pub const Worker = struct {
    idle_node: IdleQueue.Node,
    active_node: ActiveQueue.Node = ActiveQueue.Node{},
    run_queue: BoundedQueue = BoundedQueue{},
    run_queue_overflow: UnboundedQueue,
    run_queue_lifo: Atomic(?*Task) = Atomic(?*Task).init(null),
    run_queue_next: ?*Task = null,
    target_iter: Scheduler.WorkerIter,
    sched_state: usize,

    fn isWaking(self: Worker) bool {
        return self.sched_state & 1 != 0;
    }

    fn setWaking(self: *Worker, is_waking: bool) void {
        self.sched_state = @ptrToInt(self.getScheduler()) | @boolToInt(is_waking);
    }

    pub fn getScheduler(self: *Worker) *Scheduler {
        @setRuntimeSafety(false);
        return @intToPtr(*Scheduler, self.sched_state & ~@as(usize, 1));
    }

    pub const ScheduleHints = struct {
        use_lifo: bool = false,
        use_next: bool = false,
    };

    pub fn schedule(self: *Worker, tasks: Batch, hints: ScheduleHints) void {
        var batch = tasks;
        if (batch.isEmpty()) {
            return;
        }

        if (hints.use_next) {
            const old_next = self.run_queue_next;
            self.run_queue_next = batch.pop();
            batch.pushFront(old_next orelse return);
        }

        if (hints.use_lifo) {
            if (self.run_queue_lifo.swap(batch.popFront(), .release)) |old_lifo| {
                batch.pushFront(old_lifo);
            }
        }

        if (self.run_queue.tryPush(batch)) |overflowed| {
            self.run_queue_overflow.push(overflowed);
        }

        const scheduler = self.getScheduler();
        scheduler.resumeWorker(self.is_waking);
        self.is_waking = false;
    }
    
    pub const PollScope = enum {
        local,
        global,
        shared,
    };

    pub fn poll(self: *Worker, scope: PollScope) ?*Task {
        const scheduler = self.getScheduler();
        const task = switch (scope) {
            .local => self.pollLocal(),
            .global => self.pollGlobal(scheduler),
            .shared => self.pollShared(scheduler),
        };

        if (task != null) {
            if (self.isWaking()) {
                self.setWaking(false);
                scheduler.resumeWorker(true);
            }
        }
        
        return task;
    }

    fn pollLocal(self: *Worker) ?*Task {
        if (self.run_queue_next) |next| {
            const task = next;
            self.run_queue_next = null;
            return task;
        }

        if (self.pollLifo(false)) |task| {
            return task;
        }

        if (self.run_queue.pop()) |task| {
            return task;
        }

        if (self.run_queue.popAndStealUnbounded(&self.run_queue_overflow)) |task| {
            return task;
        }

        return null;
    }

    fn pollLifo(self: *Worker, comptime is_remote: bool) ?*Task {
        var task = self.run_queue_lifo.load(.relaxed);
        if (task == null) {
            return null;
        }

        // For remote run_queue_lifo steals, the task writes .release'd need to be .acquire'd.
        // For non-remote (or local) run_queue_lifo steals, no stricter memory orderings are required.
        // We use .consume instead of .acquire as the *Task that we read is a data-dependency of the atomic steal.
        const ordering = if (is_remote) .consume else .relaxed;

        // On x86, a `lock xchg` is generally faster than a `lock cmpxchg` as below.
        if (core.is_x86) {
            return self.run_queue_lifo.swap(null, ordering);
        }

        // For other architectures, we use a compare-and-swap() instead of a swap().
        // Under LL/SC, this doesn't result in an extra store on failure compared to the latter.
        while (task != null) {
            task = self.run_queue_lifo.tryCompareAndSwap(
                task,
                null,
                ordering,
                .relaxed,
            ) orelse return task;
        }

        return null;
    }

    fn pollGlobal(self: *Worker, scheduler: *Scheduler) ?*Task {
        // All that there is to check is the scheduler's queue.
        // TODO: have different task queues for different priorities.
        if (self.run_queue.popAndStealUnbounded(&scheduler.run_queue)) |task| {
            return task;
        }

        return null;
    }

    fn pollShared(self: *Worker, scheduler: *Scheduler) ?*Task {
        var active_workers = scheduler.worker_queue.loadSpawnedCount(.relaxed);
        while (active_workers > 0) : (active_workers -= 1) {
            
            const target = self.target_iter.next() orelse blk: {
                self.target_iter = scheduler.iter();
                const target = self.target_iter.next();
                break :blk (target orelse core.panic("Worker.pollShared() without a target"));
            };

            if (target == self) {
                continue;
            }

            if (
                self.run_queue.popAndStealBounded(&target.run_queue) orelse
                self.run_queue.popAndStealUnbounded(&target.run_queue_overflow) orelse
                target.pollLifo(true)
            ) |task| {
                return task;
            }
        }
        
        return null;
    }
};

pub const Scheduler = struct {
    idle_queue: IdleQueue = IdleQueue{},
    active_queue: ActiveQueue = ActiveQueue{},
    worker_queue: WorkerQueue = WorkerQueue{},
    run_queue: UnboundedQueue,
    syscallFn: Syscall.Fn,

    pub fn init(self: *Scheduler, syscallFn: Syscall.Fn) void {

    }

    pub fn deinit(self: *Scheduler) void {

    }

    pub fn iter(self: *Scheduler) WorkerIter {
        return WorkerIter{
            .iter = self.active_queue.iter(),
        };
    }

    pub const WorkerIter = struct {
        iter: ActiveQueue.Iter,

        pub fn next(self: *WorkerIter) ?*Worker {
            const active_node = self.iter.next() orelse return null;
            return @fieldParentPtr(Worker, "active_node", active_node);
        }
    };

    pub fn schedule(self: *Scheduler, batch: Batch) void {
        if (batch.isEmpty()) {
            return;
        }

        self.run_queue.push(batch);
        self.resumeWorker(false);
    }

    fn syscall(self: *Scheduler, operation: Syscall) bool {

    }

    fn resumeWorker(self: *Scheduler, is_caller_waking: bool) void {

    }

    fn suspendWorker(self: *Scheduler, worker: *Worker) Suspend {

    }

    pub fn shutdown(self: *Scheduler) void {
        
    }
};

pub const Syscall = union(enum) {
    spawned: Spawned,
    resumed: Resumed,
    suspended: Suspended,
    polled: Polled,
    executed: Executed,

    pub const Function = fn(*Scheduler, @This()) bool;

    pub const Spawned = struct {
        scheduler: *Scheduler,
        intent: Intent,

        pub const Intent = enum {
            first,
            normal,
            last,
        };
    };

    pub const Resumed = struct {
        worker: *Worker,
        intent: Intent,

        pub const Intent = enum {
            first,
            normal,
            last,
            join,
        };
    };

    pub const Suspended = struct {
        worker: *Worker,
        intent: Intent,

        pub const Intent = enum {
            first,
            normal,
            last,
        };
    };

    pub const Polled = struct {
        batch: *Batch,
        intent: Intent,

        pub const Intent = enum {
            eager,
            last_resort,
        };
    };

    pub const Executed = struct {
        worker: *Worker,
        task: *Task,
    };
};

/////////////////////////////////////////////////////////////////////

const UnboundedQueue = struct {
    is_consuming: Atomic(bool),
    head: Atomic(*Task),
    tail: *Task,
    stub: Task,

    fn init(self: *UnboundedQueue) void {
        self.is_consuming.set(false);
        self.head.set(&self.stub);
        self.tail = &self.stub;
        self.stub.next = null;
    }
};

const BoundedQueue = struct {
    head: Atomic(u32) = Atomic(u32).init(0),
    tail: Atomic(u32) = Atomic(u32).init(0),
    buffer: [capacity]Atomic(*Task) = undefined,

    const capacity = 256;
};

const ActiveQueue = struct {
    head: Atomic(?*Node) = Atomic(?*Node).init(null),

    const Node = struct {
        next: ?*Node = null,
    };

    fn push(self: *ActiveQueue, node: *Node) void {
        var head = self.head.load(.relaxed);
        while (true) {
            node.next = head;
            head = self.head.tryCompareAndSwap(
                head,
                node,
                .release,
                .relaxed,
            ) orelse break;
        }
    }

    fn iter(self: *const ActiveQueue) Iter {
        return Iter{
            .node = self.head.load(.consume),
        };
    }

    const Iter = struct {
        node: ?*Node,

        fn next(self: *Iter) ?*Node {
            const node = self.node orelse return null;
            self.node = node.next;
            return node;
        }
    };
};

const IdleQueue = struct {
    state: Atomic(usize) = Atomic(usize).init(EMPTY),

    const EMPTY: usize = 0;
    const NOTIFIED: usize = 1;
    const SHUTDOWN: usize = 2;
    const WAITING: usize = ~(EMPTY | NOTIFIED | SHUTDOWN);

    const Node = struct {
        next: ?*Node align(~WAITING + 1) = null,
    };

    fn wait(self: *IdleQueue, node: *Node) void {

    }

    fn notify(self: *IdleQueue) void {

    }

    fn shutdown(self: *IdleQueue) void {

    }
};

const WorkerQueue = struct {
    max_workers: u16,
    counter: Atomic(u32) = Atomic(u32).init((Counter{}).pack()),

    const State = enum(u4) {
        pending = 0,
        notified,
        waking,
        waking_notified,
        shutdown,
    };

    const Counter = struct {
        idle: u16 = 0,
        spawned: u16 = 0,
        state: State = .pending,

        fn pack(self: Counter) u32 {
            return (
                @as(u32, @enumToInt(self.state)) |
                (@as(u32, @intCast(u14, self.spawned)) << 4) | 
                (@as(u32, @intCast(u14, self.idle)) << (4 + 14)) 
            );
        }

        fn unpack(value: u32) Counter {
            return Counter{
                .state = @intToEnum(State, @truncate(u4, value)),
                .spawned = @truncate(u14, value >> 4),
                .idle = @truncate(u14, value >> (4 + 14)),
            };
        }
    };

    fn loadSpawnedCount(self: *const WorkerQueue, comptime ordering: Ordering) u16 {
        const counter_value = self.counter.load(ordering);
        const counter = Counter.unpack(counter_value);
        return counter.spawned;
    }
};
