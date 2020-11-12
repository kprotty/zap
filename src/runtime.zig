const std = @import("std");
const is_debug = std.debug.runtime_safety;
const is_single_threaded = std.builtin.single_threaded;

const Runtime = @This();

async_scheduler: Scheduler,
blocking_scheduler: if (is_single_threaded) void else Scheduler,

fn ReturnTypeOf(comptime asyncFn: anytype) type {
    return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
}

///////////////////////////////////////////////////////////////////////
// Generic Runtime API
///////////////////////////////////////////////////////////////////////

pub const Config = struct {
    async_pool: Pool = Pool{
        .threads = null,
        .stack_size = 16 * 1024 * 1024,
    },
    blocking_pool: Pool = Pool{
        .threads = 64,
        .stack_size = 1 * 1024 * 1024,
    },

    pub const Pool = struct {
        threads: ?u16,
        stack_size: usize,
    };

    pub fn run(self: Config, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        return self.runWithShutdown(true, asyncFn, args);
    }

    pub fn runForever(self: Config, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        return self.runWithShutdown(false, asyncFn, args);

    fn runWithShutdown(self: Config, shutdown_after: bool, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
        const Decorator = struct {
            fn entry(task: *Task, result: *?ReturnTypeOf(asyncFn), shutdown: bool, asyncArgs: @TypeOf(args)) void {
                suspend task.* = Task.init(@frame());
                const return_value = @call(.{}, asyncFn, asyncArgs);
                suspend {
                    result.* = return_value;
                    if (shutdown) {
                        Worker.getCurrent().getScheduler().shutdown();
                    }
                }
            }
        };

        var task: Task = undefined;
        var result: ?ReturnTypeOf(asyncFn) = null;
        var frame = async Decorator.entry(&task, &result, shutdown_after, args);


    }
};

pub fn getAllocator() *Allocator {
    return Worker.getCurrent().getAllocator();
}

pub fn runConcurrently() void {
    suspend {
        var task = Task.init(@frame());
        Worker.getCurrent().schedule(&task, .{ .use_lifo = true });
    }
}

pub fn spawn(allocator: *Allocator, comptime asyncFn: anytype, args: anytype) error{OutOfMemory}!void {
    if (ReturnTypeOf(asyncFn) != void) {
        @compileError("the return type of a spawned function must be void");
    }

    const Decorator = struct {
        fn entry(frame_allocator: *Allocator, asyncArgs: @TypeOf(args)) void {
            runConcurrently();
            @call(.{}, asyncFn, asyncArgs);
            suspend frame_allocator.destroy(@frame());
        }
    };

    const frame = try allocator.create(@Frame(Decorator.entry));
    frame.* = async Decorator.entry(allocator, args);
}

pub fn yield() void {
    suspend {
        var task = Task.init(@frame());
        Worker.getCurrent().schedule(&task, .{});
    }
}

pub fn callBlocking(comptime asyncFn: anytype, args: anytype) ReturnTypeOf(asyncFn) {
    if (is_single_threaded)
        return @call(.{}, asyncFn, args);

    const scheduler = Worker.getCurrent().getScheduler();
    const blocking_scheduler = scheduler.getRuntime().blocking_scheduler;

    if (scheduler != blocking_scheduler) {
        suspend {
            var task = Task.init(@frame());
            blocking_scheduler.schedule(Batch.from(&task));
        }
    }

    defer if (scheduler != blocking_scheduler) {
        suspend {
            var task = Task.init(@frame());
            scheduler.schedule(Batch.from(&task));
        }
    };

    return @call(.{}, asyncFn, args);
}

///////////////////////////////////////////////////////////////////////
// Customizable Runtime API
///////////////////////////////////////////////////////////////////////

pub const Task = struct {
    next: ?*Task = undefined,
    runnable: usize,

    pub fn init(frame: anyframe) Task {
        if (@alignOf(anyframe) < 2)
            @compileError("anyframe does not meet the minimum alignment requirement");
        return Task{ .runnable = @ptrToInt(frame) };
    }

    pub const Callback = fn(*Task) callconv(.C) void;

    pub fn initCallback(callback: Callback) Task {
        if (@alignOf(Callback) < 2)
            @compileError("Callback does not meet the minimum alignment requirement");
        return Task{ .runnable = @ptrToInt(callback) | 1 };
    }

    pub fn execute(self: *Task) void {
        @setRuntimeSafety(false);

        const runnable = self.runnable;
        if (runnable & 1 != 0) {
            const callback = @intToPtr(Callback, runnable & ~@as(usize, 1));
            return (callback)(self);
        }

        const frame = @intToPtr(anyframe, runnable);
        resume frame;
    }
};

pub const Batch = struct {
    head: ?*Task = null,
    tail: *Task = undefined,

    pub fn from(entity: anytype) Batch {
        if (@TypeOf(entity) == Batch)
            return entity;

        if (@TypeOf(entity) == *Task) {
            entity.next = null;
            return Batch{
                .head = entity,
                .tail = entity,
            };
        }

        if (@TypeOf(entity) == ?*Task) {
            const task: *Task = entity orelse return Batch{};
            return Batch.from(task);
        }

        return @compileError(@typeName(@TypeOf(entity)) ++ " cannot be converted into a " ++ @typeName(Batch));
    }

    pub fn isEmpty(self: Batch) bool {
        return self.head == null;
    }

    pub fn push(self: *Batch, entity: anytype) void {
        return self.pushBack(entity);
    }

    pub fn pushBack(self: *Batch, entity: anytype) void {
        const other = Batch.from(entity);
        if (self.isEmpty()) {
            self.* = other;
        } else {
            self.tail.next = other.head;
            self.tail = other.tail;
        }
    }

    pub fn pushFront(self: *Batch, entity: anytype) void {
        const other = Batch.from(entity);
        if (self.isEmpty()) {
            self.* = other;
        } else {
            other.tail.next = self.head;
            self.head = other.head;
        }
    }

    pub fn pop(self: *Batch) ?*Task {
        return self.popFront();
    }

    pub fn popFront(self: *Batch) ?*Task {
        const task = self.head orelse return null;
        self.head = task.next;
        return task;
    }
};

pub const Worker = struct {
    idle_node: IdleQueue.Node = IdleQueue.Node{},
    active_node: ActiveQueue.Node = ActiveQueue.Node{},
    run_queue: BoundedQueue = BoundedQueue{},
    run_queue_next: ?*Task = null,
    run_queue_lifo: ?*Task = null,
    run_queue_overflow: UnboundedQueue,
    sibling_iter: ActiveQueue.Iter,
    sched_state: usize,

    threadlocal var tls_current: ?*Worker = null;

    pub fn getCurrent() *Worker {
        return tls_current orelse {
            std.debug.panic("Worker.getCurrent() called outside of the runtime", .{})
        };
    }

    pub const ScheduleHints = struct {
        use_next: bool = false,
        use_lifo: bool = false,
    };

    pub fn schedule(self: *Worker, entity: anytype, hints: ScheduleHints) void {
        var batch = Batch.from(entity);
        if (batch.isEmpty()) {
            return;
        }

        if (hints.use_next) {
            const old_next = self.run_queue_next;
            self.run_queue_next = batch.popFront();
            if (old_next) |next| {
                batch.pushFront(next);
            }
            if (batch.isEmpty()) {
                return;
            }
        }

        if (hints.use_lifo) {
            if (@atomicRmw(?*Task, &self.run_queue_lifo, .Xchg, batch.popFront(), .AcqRel)) |old_lifo| {
                batch.pushFront(old_lifo);
            }
        }

        if (!batch.isEmpty()) {
            if (self.run_queue.push(batch)) |overflowed| {
                self.run_queue_overflow.push(overflowed);
            }
        }

        const scheduler = self.getScheduler();
        scheduler.resumeWorker(false);
    }
};

pub const Scheduler = struct {
    is_blocking: bool,
    run_queue: UnboundedQueue,
    idle_queue: IdleQueue = IdleQueue{},
    active_queue: ActiveQueue = ActiveQueue{},
    worker_queue: WorkerQueue = WorkerQueue{},

    fn getRuntime(self: *Scheduler) *Runtime {
        if (self.is_blocking)
            return @fieldParentPtr(Runtime, "blocking_scheduler", self);
        return @fieldParentPtr(Runtime, "async_scheduler", self);
    }

    pub fn schedule(self: *Scheduler, entity: anytype) void {
        const batch = Batch.from(entity);
    }

    pub fn shutdown(self: *Scheduler) void {
        const pending_workers = self.worker_queue.shutdown();

        var idle_workers = self.idle_queue.shutdown();
        while (idle_workers.next()) |idle_node| {
            const worker = @fieldParentPtr(Worker, "idle_node", idle_node);
            worker.notify();
        }
    }

    fn resumeWorker(self: *Scheduler, is_caller_waking: bool) void {
        var is_waking = is_caller_waking;

        var remaining_attempts: u8 = 5;
        while (remaining_attempts > 0) : (remaining_attempts -= 1) {
            
            var is_first: bool = undefined;
            const idle_worker = switch (self.worker_queue.tryResume(is_waking)) {
                .spawned => |instance| is_first = instance == 0,
                .resumed => switch (self.idle_queue.notify()) {
                    .resumed => |worker| worker,
                    .notified, .shutdown => return,
                },
                .notified, .shutdown => return,
            };

            if (idle_worker) |worker| {
                @compileError("TODO")
            }
        }
    }
};

///////////////////////////////////////////////////////////////////////
// Internal Runtime API
///////////////////////////////////////////////////////////////////////

const UnboundedQueue = struct {
    has_popper: bool,
    head: *Task,
    tail: *Task,
    stub: Task,

    fn init(self: *UnboundedQueue) void {
        self.has_popper = false;
        self.head = &self.stub;
        self.tail = &self.stub;
        self.stub.next = null;
    }

    fn push(self: *UnboundedQueue, entity: anytype) void {
        const batch = Batch.from(entity);

        const prev = @atomicRmw(*Task, &self.head, .Xchg, batch.tail, .AcqRel);

        @atomicStore(?*Task, &prev.next, batch.head, .Release);
    }

    fn beginPop(self: *UnboundedQueue) bool {
        return !(
            self.isEmpty() or
            @atomicLoad(bool, &self.has_popper, .Monotonic) or
            @atomicRmw(bool, &self.has_popper, .Xchg, true, .Acquire)
        );
    }

    fn endPop(self: *UnboundedQueue) void {
        @atomicStore(bool, &self.has_popper, false, .Release);
    }

    fn pop(self: *UnboundedQueue) ?*Task {
        var tail = self.tail;
        var next = @atomicLoad(?*Task, &tail.next, .Acquire);

        if (tail == &self.stub) {
            tail = next orelse return null;
            self.tail = tail;
            next = @atomicLoad(?*Task, &tail.next, .Acquire);
        }

        if (next) |new_tail| {
            self.tail = new_tail;
            return tail;
        }

        const head = @atomicLoad(*Task, &self.head, .Acquire);
        if (head != tail) {
            return null;
        }

        self.push(&self.stub);

        next = @atomicLoad(?*Task, &tail.next, .Acquire);
        if (next) |new_tail| {
            self.tail = new_tail;
            return tail;
        }

        return null;
    }
};

const BoundedQueue = extern struct {
    head: usize = 0,
    tail: usize = 0,
    buffer: [capacity]*Task = undefined,

    const capacity = 256;

    fn push(self: *BoundedQueue, entity: anytype) ?Batch {
        var batch = Batch.from(entity);
        var tail = self.tail;
        var head = @atomicLoad(usize, &self.head, .Monotonic);

        while (true) {
            if (batch.isEmpty()) {
                return null;
            }

            var remaining = capacity - (tail -% head);
            if (remaining > 0) {
                while (remainig > 0) : (remaining -= 1) {
                    const task = batch.pop() orelse break;
                    @atomicStore(*Task, &self.buffer[tail % capacity], task, .Unordered);
                    tail +%= 1;
                }

                @atomicStore(usize, &self.tail, tail, .Release);

                std.SpinLock.loopHint(1);
                head = @atomicLoad(usize, &self.head, .Monotonic);
                continue;
            }

            const new_head = head +% (capacity / 2);
            if (@cmpxchgWeak(
                usize,
                &self.head,
                head,
                new_head,
                .Acquire,
                .Monotonic,
            )) |updated| {
                head = updated;
                continue;
            }

            var overflowed = Batch{};
            while (head != new_head) : (head +% 1) {
                const task = self.buffer[head % capacity];
                overflowed.push(task);
            }
            
            overflowed.pushBack(batch);
            return overflowed;
        }
    }

    fn pop(self: *BoundedQueue) ?*Task {
        var tail = self.tail;
        var head = @atomicLoad(usize, &self.head, .Monotonic);

        while (true) {
            if (tail == head) {
                return null;
            }

            head = @cmpxchgWeak(
                usize,
                &self.head,
                head,
                head +% 1,
                .Acquire,
                .Monotonic,
            ) orelse return self.buffer[head % capacity];
        }
    }

    fn popAndStealBounded(self: *BoundedQueue, target: *BoundedQueue) ?*Task {
        if (target == self) {
            return self.pop();
        }
        
        const tail = self.tail;
        const head = @atomicLoad(usize, &self.head, .Monotonic);
        if (tail != head) {
            return self.pop();
        }

        var target_head = @atomicLoad(usize, &target.head, .Monotonic);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.tail, .Acquire);
            const target_size = target_tail -% target_head;

            var steal = target_size - (target_size / 2);
            if (steal == 0) {
                return null;
            }

            if (steal > capacity / 2) {
                std.SpinLock.loopHint(1);
                target_head = @atomicLoad(usize, &target.head, .Monotonic);
                continue;
            }

            const first_task = @atomicLoad(*Task, &target.buffer[target_head % capacity], .Unordered);
            var new_target_head = target_head +% 1;
            var new_tail = tail;
            steal -= 1;

            while (steal > 0) : (steal -= 1) {
                const task = @atomicLoad(*Task, &target.buffer[new_target_head % capacity], .Unordered);
                new_target_head +%= 1;
                @atomicStore(*Task, &self.buffer[new_tail % capacity], task, .Unordered);
                new_tail +%= 1;
            }

            if (@cmpxchgWeak(
                usize,
                &target.head,
                target_head,
                new_target_head,
                .Release,
                .Monotonic,
            )) |updated| {
                target_head = updated;
                continue;
            }

            if (new_tail != tail) {
                @atomicStore(usize, &self.tail, new_tail, .Release);
            }

            return first_task;
        }
    }

    fn popAndStealUnbounded(self: *BoundedQueue, target: *UnboundedQueue) ?*Task {
        if (!target.beginPop()) {
            return null;
        }

        const tail = self.tail;
        const head = @atomicLoad(usize, &self.head, .Monotonic);
        const first_task = target.pop();
        
        var new_tail = self.tail;
        var remaining = capacity - (tail -% head); 
        while (remaining > 0) : (remaining -= 1) {
            const task = target.pop() orelse break;
            @atomicStore(*Task, &self.buffer[new_tail % capacity], task, .Unordered);
            new_tail +%= 1;
        }

        target.endPop();

        if (new_tail != tail) {
            @atomicStore(usize, &self.tail, new_tail, .Release);
        }

        return first_task;
    }
};

const ActiveQueue = struct {
    head: ?*Node = null,

    const Node = struct {
        next: ?*Node = null,
    };

    const Iter = struct {
        node: ?*Node,

        fn next(self: *Iter) ?*Node {
            const node = self.node;
            self.node = node.next;
            return node;
        }
    };

    fn push(self: *ActiveQueue, node: *Node) void {
        var head = @atomicLoad(?*Node, &self.head, .Monotonic);

        while (true) {
            node.next = head;
            head = @cmpxchgWeak(
                ?*Node,
                &self.head,
                head,
                node,
                .Release,
                .Monotonic,
            ) orelse break;
        }
    }

    fn iter(self: *ActiveQueue) Iter {
        const node = @atomicLoad(?*Node, &self.head, .Acquire);
        return Iter{ .node = node };
    }
};

const IdleQueue = struct {
    state: usize = EMPTY,

    const EMPTY: usize = 0;
    const NOTIFIED: usize = 1;
    const SHUTDOWN: usize = 2;
    const WAITING: usize = ~(EMPTY | NOTIFIED | SHUTDOWN);

    const Node = struct {
        next: ?*Node align(~WAITING + 1) = null,
    };

    const Wait = union(enum) {
        suspended: *Node,
        notified: void,
        shutdown: void,
    };

    fn wait(self: *IdleQueue, node: *Node) Wait {
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            if (state == SHUTDOWN) {
                return .shutdown;
            }

            if (state == NOTIFIED) {
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    EMPTY,
                    .Monotonic,
                    .Monotonic,
                ) orelse return .notified;
                continue;
            }

            node.next = blk: {
                @setRuntimeSafety(false);
                break :blk @intToPtr(?*Node, state & WAITING);
            };

            state = @cmpxchgWeak(
                usize
                &self.state,
                state,
                @ptrToInt(node),
                .Release,
                .Monotonic,
            ) orelse return .{ .waiting = node };
        }
    }

    const Notify = union(enum) {
        resumed: *Node,
        notified: void,
        shutdown: void,
    };

    fn notify(self: *IdleQueue) Notify {
        var state = @atomicLoad(usize, &self.state, .Acquire);

        while (true) {
            if (state == SHUTDOWN) {
                return .shutdown;
            }

            if (state == EMPTY) {
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    NOTIFIED,
                    .Acquire,
                    .Acquire,
                ) orelse return .notified;
                continue;
            }

            const node = blk: {
                @setRuntimeSafety(false);
                break :blk @intToPtr(?*Node, state & WAITING);
            };

            state = @cmpxchgWeak(
                usize
                &self.state,
                state,
                @ptrToInt(node.next),
                .Acquire,
                .Acquire,
            ) orelse return .{ .resumed = node };
        }
    }

    const Iter = struct {
        node: ?*Node,

        fn next(self: *Iter) ?*Node {
            const node = self.node;
            self.node = node.next;
            return node;
        }
    };

    fn shutdown(self: *IdleQueue) Iter {
        const state = @atomicRmw(usize, &self.state, .Xchg, SHUTDOWN, .Acquire);

        const node = switch (state) {
            NOTIFIED => null,
            SHUTDOWN => std.debug.panic("IdleQueue shutdown multiple times", .{}),
            else => blk: {
                @setRuntimeSafety(false);
                break :blk @intToPtr(?*Node, state & WAITING);
            },
        };

        return Iter{ .node = node };
    }
};

const WorkerQueue = struct {
    counter: u32 = (Counter{}).pack(),
    max_workers: u16,

    const State = enum(u4) {
        pending = 0,
        resuming,
        resume_notified,
        suspend_notified,
        shutdown,
    };

    const Counter = struct {
        spawned: u16 = 0,
        suspended: u16 = 0,
        state: State = .pending,

        fn pack(self: Counter) u32 {
            var value: u32 = 0;
            value |= @as(u32, @enumToInt(self.state));
            value |= @as(u32, @intCast(u14, self.spawned)) << 4;
            value |= @as(u32, @intCast(u14, self.suspended)) << (4 + 14);
            return value;
        }

        fn unpack(value: u32) Counter {
            var self: Counter = undefined;
            self.state = @intToEnum(State, @truncate(u4, value));
            self.spawned = @truncate(u14, value >> 4);
            self.suspended = @truncate(u14, value >> (4 + 14));
            return self;
        }
    };

    fn getCounter(self: *const WorkerQueue) Counter {
        const value = @atomicLoad(u32, &self.counter, .Monotonic);
        return Counter.unpack(value);
    }

    const Resume = union(enum) {
        spawned: u16,
        resumed: u16,
        notified: bool,
        shutdown: void,
    };

    fn tryResume(self: *WorkerQueue, is_caller_resuming: bool) Resume {

    }

    fn cancelResume(self: *WorkerQueue) void {

    }

    const Suspend = union(enum) {
        notified: void,
        suspended: u16,
        shutdown: u16,
    };

    fn trySuspend(self: *WorkerQueue, is_caller_resuming: bool) Suspend {

    }

    fn shutdown(self: *WorkerQueue) u16 {

    }
};
