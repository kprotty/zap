const std = @import("std");
const Loop = @This();

counter: usize = 0,
stack_size: usize,
max_workers: usize,
idle_lock: Lock = .{},
idle_workers: ?*Worker = null,
spawned_workers: ?*Worker = null,
run_queues: [Priority.ARRAY_SIZE]GlobalQueue = [_]GlobalQueue{.{}} ** Priority.ARRAY_SIZE,

pub const RunConfig = struct {
    max_threads: ?usize = null,
    stack_size: ?usize = null,
};

fn ReturnTypeOf(comptime asyncFn: anytype) type {
    return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
}

pub fn run(config: RunConfig, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
    const Args = @TypeOf(args);
    const Result = ReturnTypeOf(asyncFn);
    const Wrapper = struct {
        fn entry(task: *Task, result: *?Result, arguments: Args) void {
            suspend task.* = Task.init(@frame());
            const res = @call(.{}, asyncFn, arguments);
            result.* = res; // TODO: check if this hack is still needed
            suspend Worker.getCurrent().?.loop.shutdown();
        }
    };

    var task: Task = undefined;
    var result: ?Result = null;
    var frame = async Wrapper.entry(&task, &result, args);
    runTask(config, &task);   
    return result orelse error.AsyncFnDidNotComplete;
}

pub fn runTask(config: RunConfig, task: *Task) void {
    if (std.builtin.single_threaded)
        @compileError("TODO: specialize for single_threaded");

    const stack_size = blk: {
        const stack_size = config.stack_size orelse 16 * 1024 * 1024;
        break :blk std.math.max(std.mem.page_size, stack_size);
    };

    const max_workers = blk: {
        const max_threads = config.max_threads orelse std.Thread.cpuCount() catch 1;
        break :blk std.math.max(1, max_threads);
    };
    
    var loop = Loop{
        .max_workers = max_workers,
        .stack_size = stack_size,
    };
    defer loop.idle_lock.deinit();

    loop.run_queues[0].push(Batch.from(task));
    loop.counter = (Counter{
        .state = .waking,
        .notified = false,
        .idle = 0,
        .spawned = 1,
    }).pack();

    Worker.run(&loop, null);
}

pub const Task = struct {
    next: ?*Task = undefined,
    data: usize,

    pub fn init(frame: anyframe) Task {
        return .{ .data = @ptrToInt(frame) | 0 };
    }

    pub const Callback = fn(*Task) callconv(.C) void;

    pub fn initCallback(callback: Callback) void {
        return .{ .data = @ptrToInt(callback) | 1 };
    }

    fn run(self: *Task) void {
        switch (self.data & 1) {
            0 => resume @intToPtr(anyframe, self.data),
            1 => @intToPtr(Callback, self.data & ~@as(usize, 1))(self),
            else => unreachable,
        }
    }
};

pub const Priority = enum(u2) {
    Low = 0,
    Normal = 1,
    High = 2,
    Handoff = 3,

    const ARRAY_SIZE = 3;

    fn toArrayIndex(self: Priority) usize {
        return switch (self) {
            .Handoff, .High => 2,
            .Normal => 1,
            .Low => 0,
        };
    }
};

pub fn scheduleRemote(self: *Loop, task: *Task, priority: Priority) void {
    self.run_queues[priority.toArrayIndex()].push(Batch.from(task));
    self.notifyWorkersWith(null);
}

pub fn schedule(task: *Task, priority: Priority) void {
    const worker = Worker.getCurrent() orelse @panic("Loop.schedule called outside of worker thread pool");
    worker.schedule(Batch.from(task), priority);
}

const Counter = struct {
    state: State = .pending,
    notified: bool = false,
    idle: usize = 0,
    spawned: usize = 0,

    const count_bits = @divFloor(std.meta.bitCount(usize) - 3, 2);
    const Count = std.meta.Int(.unsigned, count_bits);
    const State = enum(u2) {
        pending = 0,
        waking,
        signaled,
        shutdown,
    };

    fn pack(self: Counter) usize {
        return (
            (@as(usize, @enumToInt(self.state)) << 0) |
            (@as(usize, @boolToInt(self.notified)) << 2) |
            (@as(usize, @intCast(Count, self.idle)) << 3) |
            (@as(usize, @intCast(Count, self.spawned)) << (3 + count_bits))
        );
    }

    fn unpack(value: usize) Counter {
        return .{
            .state = @intToEnum(State, @truncate(u2, value)),
            .notified = value & (1 << 2) != 0,
            .idle = @truncate(Count, value >> 3),
            .spawned = @truncate(Count, value >> (3 + count_bits)),
        };
    }
};

fn getWorkerCount(self: *const Loop) usize {
    const counter = Counter.unpack(@atomicLoad(usize, &self.counter, .Monotonic));
    return counter.spawned;
}

fn getWorkerIter(self: *const Loop) WorkerIter {
    const spawned_workers = @atomicLoad(?*Worker, &self.spawned_workers, .Acquire);
    return .{ .spawned = spawned_workers };
}

const WorkerIter = struct {
    spawned: ?*Worker = null,

    fn next(self: *WorkerIter) ?*Worker {
        const worker = self.spawned orelse return null;
        self.spawned = worker.spawned_next;
        return worker;
    }
};

fn beginWorkerWith(self: *Loop, worker: *Worker) void {
    var spawned_workers = @atomicLoad(?*Worker, &self.spawned_workers, .Monotonic);
    while (true) {
        worker.spawned_next = spawned_workers;
        spawned_workers = @cmpxchgWeak(
            ?*Worker,
            &self.spawned_workers,
            spawned_workers,
            worker,
            .Release,
            .Monotonic,
        ) orelse break;
    }
}

fn notifyWorkersWith(self: *Loop, worker: ?*Worker) void {
    var did_spawn = false;
    var spawn_attempts_remaining: u8 = 5;
    var is_waking = if (worker) |w| w.state == .waking else false;
    var counter = Counter.unpack(@atomicLoad(usize, &self.counter, .Monotonic));

    while (true) {
        if (counter.state == .shutdown) {
            if (did_spawn)
                self.markShutdown();
            return;
        }

        var is_spawning = false;
        var is_signaling = false;
        var new_counter = counter;

        if (is_waking) {
            std.debug.assert(counter.state == .waking);
            if (counter.idle > 0) {
                is_signaling = true;
                new_counter.state = .signaled;
                if (did_spawn)
                    new_counter.spawned -= 1;
            } else if (spawn_attempts_remaining > 0 and (did_spawn or counter.spawned < self.max_workers)) {
                is_spawning = true;
                if (!did_spawn)
                    new_counter.spawned += 1;
            } else {
                new_counter.notified = true;
                new_counter.state = .pending;
                if (did_spawn)
                    new_counter.spawned -= 1;
            }
        } else {
            if (counter.state == .pending and counter.idle > 0) {
                is_signaling = true;
                new_counter.state = .signaled;
            } else if (counter.state == .pending and counter.spawned < self.max_workers) {
                is_spawning = true;
                new_counter.state = .waking;
                new_counter.spawned += 1;
            } else if (!counter.notified) {
                new_counter.notified = true;
            } else {
                return;
            }
        }

        if (@cmpxchgWeak(
            usize,
            &self.counter,
            counter.pack(),
            new_counter.pack(),
            .Release,
            .Monotonic,
        )) |updated| {
            std.Thread.spinLoopHint();
            counter = Counter.unpack(updated);
            continue;
        }

        is_waking = true;
        if (is_signaling) {
            self.notifyOne();
            return;
        }

        if (is_spawning) {
            did_spawn = true;
            if (Worker.spawn(self))
                return;
        } else {
            return;
        }

        std.Thread.spinLoopHint();
        spawn_attempts_remaining -= 1;
        counter = Counter.unpack(@atomicLoad(usize, &self.counter, .Monotonic));
    }
}

fn suspendWorkerWith(self: *Loop, worker: *Worker) void {
    var counter = Counter.unpack(@atomicLoad(usize, &self.counter, .Monotonic));

    while (true) {
        if (counter.state == .shutdown) {
            worker.state = .shutdown;
            self.markShutdown();
            return;
        }

        if (counter.notified or counter.state == .signaled or worker.state != .waiting) {
            var new_counter = counter;
            new_counter.notified = false;
            if (counter.state == .signaled) {
                new_counter.state = .waking;
                if (worker.state == .waiting)
                    new_counter.idle -= 1;
            } else if (counter.notified) {
                if (worker.state == .waking)
                    new_counter.state = .waking;
                if (worker.state == .waiting)
                    new_counter.idle -= 1;
            } else {
                if (worker.state == .waking)
                    new_counter.state = .pending;
                if (worker.state != .waiting)
                    new_counter.idle += 1;
            }

            if (@cmpxchgWeak(
                usize,
                &self.counter,
                counter.pack(),
                new_counter.pack(),
                .Acquire,
                .Monotonic,
            )) |updated| {
                std.Thread.spinLoopHint();
                counter = Counter.unpack(updated);
                continue;
            }

            if (counter.notified or counter.state == .signaled) {
                if (counter.state == .signaled) {
                    worker.state = .waking;
                } else if (worker.state == .waiting) {
                    worker.state = .running;
                }
                return;
            }
        }

        worker.state = .waiting;
        self.wait(worker);
        counter = Counter.unpack(@atomicLoad(usize, &self.counter, .Monotonic));
    }
}

fn shutdown(self: *Loop) void {
    var counter = Counter.unpack(@atomicLoad(usize, &self.counter, .Monotonic));
    while (counter.state != .shutdown) {

        var new_counter = counter;
        new_counter.state = .shutdown;
        new_counter.idle = 0;

        if (@cmpxchgWeak(
            usize,
            &self.counter,
            counter.pack(),
            new_counter.pack(),
            .AcqRel,
            .Monotonic,
        )) |updated| {
            std.Thread.spinLoopHint();
            counter = Counter.unpack(updated);
            continue;
        }

        if (counter.idle > 0)
            self.notifyAll();
        return;
    }
}

fn markShutdown(self: *Loop) void {
    var counter = Counter{ .spawned = 1 };
    counter = Counter.unpack(@atomicRmw(usize, &self.counter, .Sub, counter.pack(), .AcqRel));

    std.debug.assert(counter.state == .shutdown);
    if (counter.spawned == 1 and counter.idle != 0) {
        self.notifyOne();
    }
}

fn joinWith(self: *Loop, worker: *Worker) void {
    var counter = Counter.unpack(@atomicLoad(usize, &self.counter, .Acquire));
    while (true) {
        if (counter.spawned == 0)
            break;

        if (counter.idle == 0) {
            var new_counter = counter;
            new_counter.idle = 1;
            if (@cmpxchgWeak(
                usize,
                &self.counter,
                counter.pack(),
                new_counter.pack(),
                .Acquire,
                .Acquire,
            )) |updated| {
                std.Thread.spinLoopHint();
                counter = Counter.unpack(updated);
                continue;
            }
        }

        self.wait(worker);
        counter = Counter.unpack(@atomicLoad(usize, &self.counter, .Acquire));
    }

    var pending_workers = self.getWorkerIter();
    while (pending_workers.next()) |pending_worker| {
        const thread = pending_worker.thread orelse continue;
        pending_worker.notify();
        thread.join();
    }
}

fn wait(self: *Loop, worker: *Worker) void {
    const is_waiting = blk: {
        const held = self.idle_lock.acquire();
        defer held.release();

        const counter = Counter.unpack(@atomicLoad(usize, &self.counter, .Monotonic));
        const should_wake = switch (worker.state) {
            .shutdown => counter.spawned == 0,
            .waiting => counter.notified or counter.state == .signaled or counter.state == .shutdown,
            else => unreachable,
        };

        if (should_wake) {
            break :blk false;
        }

        worker.idle_next = self.idle_workers;
        self.idle_workers = worker;
        break :blk true;
    };

    if (is_waiting) {
        worker.wait();
    }
}

fn notifyOne(self: *Loop) void {
    self.wake(false);
}

fn notifyAll(self: *Loop) void {
    self.wake(true);
}

fn wake(self: *Loop, wake_all: bool) void {
    const worker = blk: {
        const held = self.idle_lock.acquire();
        defer held.release();

        const worker = self.idle_workers orelse {
            return;
        };

        if (wake_all) {
            self.idle_workers = null;
        } else {
            self.idle_workers = worker.idle_next;
            worker.idle_next = null;
        }

        break :blk worker;
    };

    var idle_workers: ?*Worker = worker;
    while (idle_workers) |idle_worker| {
        idle_workers = idle_worker.idle_next;
        idle_worker.notify();
    }
}

const Worker = struct {
    loop: *Loop,
    thread: ?Thread,
    state: State = .waking,
    wait_state: usize = 0,
    idle_next: ?*Worker = null,
    spawned_next: ?*Worker = null,
    steal_targets: WorkerIter = .{},
    run_next: Batch = .{},
    run_queues: [Priority.ARRAY_SIZE]LocalQueue = [_]LocalQueue{.{}} ** Priority.ARRAY_SIZE,

    const ThreadLocalWorkerPtr = ThreadLocalUsize(struct{});
    const State = enum {
        running,
        waking,
        waiting,
        shutdown,
    };

    fn spawn(loop: *Loop) bool {
        const Spawner = struct {
            _loop: *Loop = undefined,
            _thread: Thread = undefined,
            put_event: Event = .{},
            got_event: Event = .{},

            fn entry(self: *@This()) void {
                std.debug.assert(self.put_event.wait(null));
                const _loop = self._loop;
                const _thread = self._thread;
                self.got_event.set();
                Worker.run(_loop, _thread);
            }
        };
        
        var spawner = Spawner{};
        defer {
            spawner.put_event.deinit();
            spawner.got_event.deinit();
        }

        spawner._loop = loop;
        spawner._thread = Thread.spawn(loop.stack_size, &spawner, Spawner.entry) catch return false;
        spawner.put_event.set();
        std.debug.assert(spawner.got_event.wait(null));
        return true;
    }

    fn run(loop: *Loop, thread: ?Thread) void {
        var self = Worker{
            .loop = loop,
            .thread = thread,
        };

        loop.beginWorkerWith(&self);
        ThreadLocalWorkerPtr.set(@ptrToInt(&self));

        var tick = @truncate(u8, @ptrToInt(&self) >> @sizeOf(*Worker));
        while (self.state != .shutdown) {
            tick +%= 1;

            if (self.poll(tick)) |task| {
                if (self.state == .waking)
                    loop.notifyWorkersWith(&self);
                self.state = .running;
                task.run();
                continue;    
            }

            loop.suspendWorkerWith(&self);
        }

        if (thread == null) {
            loop.joinWith(&self);
        } else {
            self.wait();
        }
    }

    fn getCurrent() ?*Worker {
        return @intToPtr(?*Worker, ThreadLocalWorkerPtr.get());
    }

    const WaitState = enum(u2) {
        Empty = 0,
        Waiting = 1,
        Notified = 3,
    };

    fn wait(self: *Worker) void {
        var event align(std.math.max(@alignOf(Event), 4)) = Event{};
        defer event.deinit();

        if (@cmpxchgStrong(
            usize,
            &self.wait_state,
            @enumToInt(WaitState.Empty),
            @enumToInt(WaitState.Waiting) | @ptrToInt(&event),
            .AcqRel,
            .Acquire,
        )) |updated| {
            std.debug.assert(@intToEnum(WaitState, @truncate(u2, updated)) == .Notified);
            @atomicStore(usize, &self.wait_state, @enumToInt(WaitState.Empty), .Monotonic);
            return;
        }

        const timeout: ?u64 = null;
        const timed_out = !event.wait(timeout);
        std.debug.assert(!timed_out);
    }

    fn notify(self: *Worker) void {
        var wait_state = @atomicLoad(usize, &self.wait_state, .Monotonic);
        while (true) {
            var new_state: WaitState = undefined;
            switch (@intToEnum(WaitState, @truncate(u2, wait_state))) {
                .Empty => new_state = .Notified,
                .Waiting => new_state = .Empty,
                .Notified => return,
            }

            if (@cmpxchgWeak(
                usize,
                &self.wait_state,
                wait_state,
                @enumToInt(new_state),
                .AcqRel,
                .Monotonic,
            )) |updated| {
                std.Thread.spinLoopHint();
                wait_state = updated;
                continue;
            }

            if (new_state == .Empty) {
                const EventPtr = *align(std.math.max(@alignOf(Event), 4)) Event;
                const event = @intToPtr(EventPtr, wait_state & ~@as(usize, 0b11));
                event.set();
            }

            return;
        }
    }

    fn schedule(self: *Worker, batch: Batch, priority: Priority) void {
        if (batch.isEmpty())
            return;

        if (priority == .Handoff) {
            self.run_next.push(batch);
        } else {
            self.run_queues[priority.toArrayIndex()].push(batch);
        }

        self.loop.notifyWorkersWith(null);
    }

    fn poll(self: *Worker, tick: u8) ?*Task {
        if (tick % 127 == 0) {
            if (self.pollSteal(null)) |task|
                return task;
        }

        if (tick % 61 == 0) {
            if (self.pollGlobal(null)) |task|
                return task;
        }

        if (self.pollLocal(false)) |task|
            return task;

        var steal_attempt: u8 = 0;
        while (steal_attempt < 4) : (steal_attempt += 1) {
            if (self.pollGlobal(steal_attempt)) |task|
                return task;

            if (self.pollSteal(steal_attempt)) |task|
                return task;
        }

        return null;
    }

    fn pollLocal(self: *Worker, be_fair: bool) ?*Task {
        var priority_order = [_]Priority{ .Handoff, .High, .Normal, .Low };
        if (be_fair) {
            priority_order = [_]Priority{ .Low, .Normal, .High, .Handoff };
        }

        for (priority_order) |priority| {
            if (priority == .Handoff) {
                if (self.run_next.pop()) |task|
                    return task;
            }

            if (self.run_queues[priority.toArrayIndex()].pop(be_fair)) |task|
                return task;
        }

        return null;
    }

    fn pollGlobal(self: *Worker, steal_attempt: ?u8) ?*Task {
        return self.pollQueues(&self.loop.run_queues, "popAndStealGlobal", steal_attempt);
    }

    fn pollSteal(self: *Worker, steal_attempt: ?u8) ?*Task {
        var iter = self.loop.getWorkerCount();
        while (iter > 0) : (iter -= 1) {
            const target = self.steal_targets.next() orelse blk: {
                self.steal_targets = self.loop.getWorkerIter();
                break :blk self.steal_targets.next() orelse unreachable;
            };

            if (target == self)
                continue;

            if (self.pollQueues(&target.run_queues, "popAndStealLocal", steal_attempt)) |task|
                return task;
        }

        return null;
    }

    fn pollQueues(
        self: *Worker,
        target_queues: anytype,
        comptime popAndStealFn: []const u8,
        steal_attempt: ?u8,
    ) ?*Task {
        const priority_order: []const Priority = blk: {
            const attempt = steal_attempt orelse {
                break :blk &[_]Priority{ .Low, .Normal, .High };
            };
            break :blk switch (attempt) {
                0 => &[_]Priority{ .High },
                1 => &[_]Priority{ .High, .Normal },
                else => &[_]Priority{ .High, .Normal, .Low },
            };
        };

        for (priority_order) |priority| {
            const be_fair = steal_attempt == null;
            const local_queue = &self.run_queues[priority.toArrayIndex()];
            const target_queue = &target_queues[priority.toArrayIndex()];
            if (@field(local_queue, popAndStealFn)(be_fair, target_queue)) |task|
                return task;
        }

        return null;
    }
};

fn ThreadLocalUsize(comptime UniqueKey: type) type {
    const is_apple_silicon = std.Target.current.isDarwin() and std.builtin.arch == .aarch64;

    // For normal platforms, we use the compilers built in "threadlocal" keyword.
    if (!is_apple_silicon) {
        return struct {
            threadlocal var tls_value: usize = 0;

            pub fn get() usize {
                return tls_value;
            }

            pub fn set(value: usize) void {
                tls_value = value;
            }
        };
    }

    // For Apple Silicon, LLD currently has some issues with it which prevents the threadlocal keyword from work correctly.
    // So for now we fallback to the OS provided thread local mechanics.
    return struct {
        const pthread_key_t = c_ulong;
        const pthread_once_t = extern struct {
            __sig: c_long = 0x30B1BCBA,
            __opaque: [4]u8 = [_]u8{ 0, 0, 0, 0 },
        };
        
        extern "c" fn pthread_once(o: *pthread_once_t, f: ?fn() callconv(.C) void) callconv(.C) c_int;
        extern "c" fn pthread_key_create(k: *pthread_key_t, d: ?fn(?*c_void) callconv(.C) void) callconv(.C) c_int;
        extern "c" fn pthread_setspecific(k: pthread_key_t, p: ?*c_void) callconv(.C) c_int;
        extern "c" fn pthread_getspecific(k: pthread_key_t) callconv(.C) ?*c_void;

        var tls_key: pthread_key_t = undefined;
        var tls_key_once: pthread_once_t = .{};

        fn tls_init() callconv(.C) void {
            std.debug.assert(pthread_key_create(&tls_key, null) == 0);
        }

        pub fn get() usize {
            std.debug.assert(pthread_once(&tls_key_once, tls_init) == 0);
            return @ptrToInt(pthread_getspecific(tls_key));
        }

        pub fn set(value: usize) void {
            std.debug.assert(pthread_once(&tls_key_once, tls_init) == 0);
            std.debug.assert(pthread_setspecific(tls_key, @intToPtr(?*c_void, value)) == 0);
        }
    };
}

const Batch = struct {
    head: ?*Task = null,
    tail: *Task = undefined,

    fn from(task: *Task) Batch {
        task.next = null;
        return Batch{
            .head = task,
            .tail = task,
        };
    }

    fn isEmpty(self: Batch) bool {
        return self.head == null;
    }

    fn push(self: *Batch, batch: Batch) void {
        if (self.isEmpty()) {
            self.* = batch;
        } else if (!batch.isEmpty()) {
            self.tail.next = batch.head;
            self.tail = batch.tail;
        }
    }

    fn pop(self: *Batch) ?*Task {
        const task = self.head orelse return null;
        self.head = task.next;
        return task;
    }
};

const GlobalQueue = UnboundedQueue;
const LocalQueue = struct {
    buffer: BoundedQueue = .{},
    overflow: UnboundedQueue = .{},

    fn push(self: *LocalQueue, batch: Batch) void {
        if (self.buffer.push(batch)) |overflowed|
            self.overflow.push(overflowed);
    }

    fn pop(self: *LocalQueue, be_fair: bool) ?*Task {
        if (be_fair) {
            if (self.buffer.popAndStealUnbounded(&self.overflow)) |task|
                return task;
        }

        if (self.buffer.pop()) |task|
            return task;

        if (self.buffer.popAndStealUnbounded(&self.overflow)) |task|
            return task;

        return null;

        // return self.buffer.pop() orelse self.buffer.popAndStealUnbounded(&self.overflow);
        // if (be_fair) {
        //     if (self.buffer.pop()) |task|
        //         return task;
        // }

        // if (self.buffer.popAndStealUnbounded(&self.overflow)) |task|
        //     return task;

        // if (self.buffer.pop()) |task|
        //     return task;

        // return null;
    }

    fn popAndStealGlobal(self: *LocalQueue, be_fair: bool, target: *GlobalQueue) ?*Task {
        return self.buffer.popAndStealUnbounded(target);
    }

    fn popAndStealLocal(self: *LocalQueue, be_fair: bool, target: *LocalQueue) ?*Task {
        if (self.buffer.popAndStealBounded(&target.buffer)) |task|
            return task;

        if (self.buffer.popAndStealUnbounded(&target.overflow)) |task|
            return task;

        return null;

        // if (self == target)
        //     return self.pop(be_fair);

        // if (be_fair) {
        //     if (self.buffer.popAndStealBounded(&target.buffer)) |task|
        //         return task;
        // }

        // if (self.buffer.popAndStealUnbounded(&target.overflow)) |task|
        //     return task;

        // if (self.buffer.popAndStealBounded(&target.buffer)) |task|
        //     return task;

        // return null;
    }
};

const UnboundedQueue = struct {
    head: ?*Task = null,
    tail: usize = 0,
    stub: Task = .{
        .next = null,
        .data = undefined,
    },

    fn push(self: *UnboundedQueue, batch: Batch) void {
        if (batch.isEmpty()) 
            return;

        const head = @atomicRmw(?*Task, &self.head, .Xchg, batch.tail, .AcqRel);
        const prev = head orelse &self.stub;
        @atomicStore(?*Task, &prev.next, batch.head, .Release);
    }

    fn tryAcquireConsumer(self: *UnboundedQueue) ?Consumer {
        // var head = @atomicLoad(?*Task, &self.head, .Monotonic);
        // if (head == null or head == &self.stub)
        //     return null;

        // var tail = @atomicRmw(usize, &self.tail, .Xchg, 1, .Acquire);
        // if (tail & 1 != 0)
        //     return null;

        while (true) : (std.Thread.spinLoopHint()) {
            const head = @atomicLoad(?*Task, &self.head, .Monotonic);
            if (head == null or head == &self.stub)
                return null;

            const tail = @atomicLoad(usize, &self.tail, .Monotonic);
            if (tail & 1 != 0)
                return null;

            _ = @cmpxchgWeak(
                usize,
                &self.tail,
                tail,
                tail | 1,
                .Acquire,
                .Monotonic,
            ) orelse return Consumer{
                .queue = self,
                .tail = @intToPtr(?*Task, tail) orelse &self.stub,
            };
        }


        // var tail = @atomicLoad(usize, &self.tail, .Monotonic);
        // while (true) : (std.Thread.spinLoopHint()) {

        //     const head = @atomicLoad(?*Task, &self.head, .Monotonic);
        //     if (head == null or head == &self.stub)
        //         return null;

        //     if (tail & 1 != 0)
        //         return null;
        //     tail = @cmpxchgWeak(
        //         usize,
        //         &self.tail,
        //         tail,
        //         tail | 1,
        //         .Acquire,
        //         .Monotonic,
        //     ) orelse return Consumer{
        //         .queue = self,
        //         .tail = @intToPtr(?*Task, tail) orelse &self.stub,
        //     };
        // }
    }

    const Consumer = struct {
        queue: *UnboundedQueue,
        tail: *Task,

        fn release(self: Consumer) void {
            @atomicStore(usize, &self.queue.tail, @ptrToInt(self.tail), .Release);
        }

        fn pop(self: *Consumer) ?*Task {
            var tail = self.tail;
            var next = @atomicLoad(?*Task, &tail.next, .Acquire);
            if (tail == &self.queue.stub) {
                tail = next orelse return null;
                self.tail = tail;
                next = @atomicLoad(?*Task, &tail.next, .Acquire);
            }

            if (next) |task| {
                self.tail = task;
                return tail;
            }

            const head = @atomicLoad(?*Task, &self.queue.head, .Monotonic);
            if (tail != head) {
                return null;
            }

            self.queue.push(Batch.from(&self.queue.stub));
            if (@atomicLoad(?*Task, &tail.next, .Acquire)) |task| {
                self.tail = task;
                return tail;
            }

            return null;
        }
    };
};

const BoundedQueue = struct {
    head: Pos = 0,
    tail: Pos = 0,
    buffer: [capacity]*Task = undefined,

    const Pos = std.meta.Int(.unsigned, std.meta.bitCount(usize) / 2);
    const capacity = 64;
    comptime {
        std.debug.assert(capacity <= std.math.maxInt(Pos));
    }

    fn push(self: *BoundedQueue, _batch: Batch) ?Batch {
        var batch = _batch;
        if (batch.isEmpty()) {
            return null;
        }

        var tail = self.tail;
        var head = @atomicLoad(Pos, &self.head, .Monotonic);
        while (true) {
            if (batch.isEmpty())
                return null;

            if (tail -% head < self.buffer.len) {
                while (tail -% head < self.buffer.len) {
                    const task = batch.pop() orelse break;
                    @atomicStore(*Task, &self.buffer[tail % self.buffer.len], task, .Unordered);
                    tail +%= 1;
                }

                @atomicStore(Pos, &self.tail, tail, .Release);
                std.Thread.spinLoopHint();
                head = @atomicLoad(Pos, &self.head, .Monotonic);
                continue;
            }

            const new_head = head +% @intCast(Pos, self.buffer.len / 2);
            if (@cmpxchgWeak(
                Pos,
                &self.head,
                head,
                new_head,
                .Acquire,
                .Monotonic,
            )) |updated| {
                std.Thread.spinLoopHint();
                head = updated;
                continue;
            }

            var overflowed = Batch{};
            while (head != new_head) : (head +%= 1) {
                const task = self.buffer[head % self.buffer.len];
                overflowed.push(Batch.from(task));
            }

            overflowed.push(batch);
            return overflowed;
        }
    }

    fn pop(self: *BoundedQueue) ?*Task {
        var tail = self.tail;
        var head = @atomicLoad(Pos, &self.head, .Monotonic);
        
        while (tail != head) {
            head = @cmpxchgWeak(
                Pos,
                &self.head,
                head,
                head +% 1,
                .Acquire,
                .Monotonic,
            ) orelse return self.buffer[head % self.buffer.len];
            std.Thread.spinLoopHint();
        }

        return null;
    }

    fn popAndStealUnbounded(self: *BoundedQueue, target: *UnboundedQueue) ?*Task {
        var consumer = target.tryAcquireConsumer() orelse return null;
        defer consumer.release();

        const tail = self.tail;
        const head = @atomicLoad(Pos, &self.head, .Monotonic);
        
        var new_tail = tail;
        var first_task: ?*Task = null;
        while (first_task == null or (new_tail -% head < self.buffer.len)) {
            const task = consumer.pop() orelse break;
            if (first_task == null) {
                first_task = task;
            } else {
                @atomicStore(*Task, &self.buffer[new_tail % self.buffer.len], task, .Unordered);
                new_tail +%= 1;
            }
        }

        if (new_tail != tail)
            @atomicStore(Pos, &self.tail, new_tail, .Release);
        return first_task;
    }

    fn popAndStealBounded(self: *BoundedQueue, target: *BoundedQueue) ?*Task {
        if (self == target)
            return self.pop();

        const head = @atomicLoad(Pos, &self.head, .Monotonic);
        const tail = self.tail;
        if (tail != head)
            return self.pop();
        
        // while (true) {
        //     const target_tail = @atomicLoad(Pos, &target.tail, .Acquire);
        //     const target_head = @atomicLoad(Pos, &target.head, .Acquire);
        //     if (target_tail == target_head)
        //         return null;

        //     if (((target_tail -% target_head) / 2) > (target.buffer.len / 2)) {
        //         std.Thread.spinLoopHint();
        //         continue;
        //     }

        //     const task = @atomicLoad(*Task, &target.buffer[target_head % target.buffer.len], .Unordered);
        //     _ = @cmpxchgWeak(
        //         Pos,
        //         &target.head,
        //         target_head,
        //         target_head +% 1,
        //         .AcqRel,
        //         .Monotonic,
        //     ) orelse return task;
        //     std.Thread.spinLoopHint();
        // }

        var target_head = @atomicLoad(Pos, &target.head, .Monotonic);
        while (true) {
            const target_tail = @atomicLoad(Pos, &target.tail, .Acquire);
            const target_size = target_tail -% target_head;
            if (target_size == 0)
                return null;

            var steal = target_size - (target_size / 2);
            if (steal > target.buffer.len / 2) {
                std.Thread.spinLoopHint();
                target_head = @atomicLoad(Pos, &target.head, .Monotonic);
                continue;
            }

            const first_task = @atomicLoad(*Task, &target.buffer[target_head % target.buffer.len], .Unordered);
            var new_target_head = target_head +% 1;
            var new_tail = tail;
            steal -= 1;

            while (steal > 0) : (steal -= 1) {
                const task = @atomicLoad(*Task, &target.buffer[new_target_head % target.buffer.len], .Unordered);
                new_target_head +%= 1;
                @atomicStore(*Task, &self.buffer[new_tail % self.buffer.len], task, .Unordered);
                new_tail +%= 1;
            }

            if (@cmpxchgWeak(
                Pos,
                &target.head,
                target_head,
                new_target_head,
                .AcqRel,
                .Monotonic,
            )) |updated| {
                std.Thread.spinLoopHint();
                target_head = updated;
                continue;
            }

            if (new_tail != tail)
                @atomicStore(Pos, &self.tail, new_tail, .Release);
            return first_task;
        }
    }
};

const Lock = if (std.builtin.os.tag == .windows)
    WindowsLock
else if (std.Target.current.isDarwin())
    DarwinLock
else if (std.builtin.link_libc)
    PosixLock
else if (std.builtin.os.tag == .linux)
    LinuxLock
else 
    @compileError("Unimplemented Lock primitive for platform");

const WindowsLock = struct {
    srwlock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Self) Held {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.srwlock);
        return Held{ .lock = self };
    }

    pub const Held = struct {
        lock: *Self,

        pub fn release(self: Held) void {
            std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.lock.srwlock);
        }
    };
};

const DarwinLock = extern struct {
    os_unfair_lock: u32 = 0,

    const Self = @This();
    extern fn os_unfair_lock_lock(lock: *Self) void;
    extern fn os_unfair_lock_unlock(lock: *Self) void;

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Self) Held {
        os_unfair_lock_lock(self);
        return Held{ .lock = self };
    }

    pub const Held = struct {
        lock: *Self,

        pub fn release(self: Held) void {
            os_unfair_lock_unlock(self.lock);
        }
    };
};

const PosixLock = struct {
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        const rc = std.c.pthread_mutex_destroy(&self.mutex);
        std.debug.assert(rc == 0 or rc == std.os.EINVAL);
        self.* = undefined;
    }

    pub fn acquire(self: *Self) Held {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        return Held{ .lock = self };
    }

    pub const Held = struct {
        lock: *Self,

        pub fn release(self: Held) void {
            std.debug.assert(std.c.pthread_mutex_unlock(&self.lock.mutex) == 0);
        }
    };
};

const LinuxLock = struct {
    state: State = .unlocked,

    const Self = @This();
    const State = enum(i32) {
        unlocked = 0,
        locked,
        contended,
    };

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Self) Held {
        if (@cmpxchgWeak(
            State,
            &self.state,
            .unlocked,
            .locked,
            .Acquire,
            .Monotonic,
        )) |_| {
            self.acquireSlow();
        }
        return Held{ .lock = self };
    }

    fn acquireSlow(self: *Self) void {
        @setCold(true);

        var spin: usize = 0;
        var lock_state = State.locked;
        var state = @atomicLoad(State, &self.state, .Monotonic);
        
        while (true) {
            if (state == .unlocked) {
                state = @cmpxchgWeak(
                    State,
                    &self.state,
                    state,
                    lock_state,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
                std.Thread.spinLoopHint();
                continue;
            }

            if (state == .locked and spin < 100) {
                spin += 1;
                std.Thread.spinLoopHint();
                state = @atomicLoad(State, &self.state, .Monotonic);
            }

            if (state != .contended) {
                if (@cmpxchgWeak(
                    State,
                    &self.state,
                    state,
                    .contended,
                    .Monotonic,
                    .Monotonic,
                )) |updated| {
                    std.Thread.spinLoopHint();
                    state = updated;
                    continue;
                }
            }

            switch (std.os.linux.getErrno(std.os.linux.futex_wait(
                @ptrCast(*const i32, &self.state),
                std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAIT,
                @enumToInt(State.contended),
                null,
            ))) {
                0 => {},
                std.os.EINTR => {},
                std.os.EAGAIN => {},
                std.os.ETIMEDOUT => unreachable,
                else => unreachable,
            }

            spin = 0;
            lock_state = .contended;
            state = @atomicLoad(State, &self.state, .Monotonic);
        }
    }

    pub const Held = struct {
        lock: *Self,

        pub fn release(self: Held) void {
            switch (@atomicRmw(State, &self.lock.state, .Xchg, .unlocked, .Release)) {
                .unlocked => unreachable,
                .locked => {},
                .contended => self.releaseSlow(),
            }
        }

        fn releaseSlow(self: Held) void {
            @setCold(true);

            switch (std.os.linux.getErrno(std.os.linux.futex_wake(
                @ptrCast(*const i32, &self.lock.state),
                std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAKE,
                1,
            ))) {
                0 => {},
                std.os.EINVAL => {},
                std.os.EACCES => {},
                std.os.EFAULT => {},
                else => unreachable,
            }
        }
    };
};

const Event = if (std.builtin.os.tag == .windows)
    WindowsEvent
else if (std.builtin.link_libc)
    PosixEvent
else if (std.builtin.os.tag == .linux)
    LinuxEvent
else 
    @compileError("Unimplemented Event primitive for platform");

const WindowsEvent = struct {
    is_set: bool = false,
    lock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,
    cond: std.os.windows.CONDITION_VARIABLE = std.os.windows.CONDITION_VARIABLE_INIT,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn set(self: *Self) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.lock);
        defer std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.lock);

        self.is_set = true;
        std.os.windows.kernel32.WakeConditionVariable(&self.cond);
    }

    threadlocal var tls_frequency: u64 = 0;

    pub fn wait(self: *Self, timeout: ?u64) bool {
        var counter: u64 = undefined;
        var frequency: u64 = undefined;
        
        if (timeout) |timeout_ns| {
            counter = std.os.windows.QueryPerformanceCounter();
            frequency = tls_frequency;
            if (frequency == 0) {
                frequency = std.os.windows.QueryPerformanceFrequency();
                tls_frequency = frequency;
            }
        }

        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.lock);
        defer std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.lock);

        while (!self.is_set) {
            var timeout_ms: std.os.windows.DWORD = std.os.windows.INFINITE;
            if (timeout) |timeout_ns| {
                const elapsed = blk: {
                    const now = std.os.windows.QueryPerformanceCounter();
                    const a = if (now >= counter) (now - counter) else 0;
                    const b = std.time.ns_per_s;
                    const c = frequency;
                    break :blk (((a / c) * b) + ((a % c) * b) / c);
                };

                if (elapsed > timeout_ns) {
                    return false;
                } else {
                    const delay_ms = @divFloor(timeout_ns - elapsed, std.time.ns_per_ms);
                    timeout_ms = std.math.cast(std.os.windows.DWORD, delay_ms) catch timeout_ms;
                }
            }

            const status = std.os.windows.kernel32.SleepConditionVariableSRW(
                &self.cond,
                &self.lock,
                timeout_ms,
                0,
            );

            if (status == std.os.windows.FALSE) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    .TIMEOUT => {},
                    else => |err| {
                        const e = std.os.windows.unexpectedError(err);
                        unreachable;
                    },
                }
            }
        }

        return true;
    }
};

const PosixEvent = struct {
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    is_set: bool = false,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        const m = std.c.pthread_mutex_destroy(&self.mutex);
        std.debug.assert(m == 0 or m == std.os.EINVAL);

        const c = std.c.pthread_cond_destroy(&self.cond);
        std.debug.assert(c == 0 or c == std.os.EINVAL);
        
        self.* = undefined;
    }

    pub fn set(self: *Self) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

        self.is_set = true;
        std.debug.assert(std.c.pthread_cond_signal(&self.cond) == 0);
    }

    pub fn wait(self: *Self, timeout: ?u64) bool {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

        var deadline: ?u64 = null;
        if (timeout) |timeout_ns| {
            deadline = timestamp(std.os.CLOCK_MONOTONIC) + timeout_ns;
        }

        while (!self.is_set) {
            const deadline_ns = deadline orelse {
                std.debug.assert(std.c.pthread_cond_wait(&self.cond, &self.mutex) == 0);
                continue;
            };

            var now_ns = timestamp(std.os.CLOCK_MONOTONIC);
            if (now_ns >= deadline_ns) {
                return false;
            } else {
                now_ns = timestamp(std.os.CLOCK_REALTIME);
                now_ns += deadline_ns - now_ns;
            }

            var ts: std.os.timespec = undefined;
            ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), @divFloor(now_ns, std.time.ns_per_s));
            ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), @mod(now_ns, std.time.ns_per_s));

            const rc = std.c.pthread_cond_timedwait(&self.cond, &self.mutex, &ts);
            std.debug.assert(rc == 0 or rc == std.os.ETIMEDOUT);
        }

        return true;
    }

    fn timestamp(comptime clock: u32) u64 {
        if (comptime std.Target.current.isDarwin()) {
            switch (clock) {
                std.os.CLOCK_REALTIME => {
                    var tv: std.os.timeval = undefined;
                    std.os.gettimeofday(&tv, null);
                    return (@intCast(u64, tv.tv_sec) * std.time.ns_per_s) + (@intCast(u64, tv.tv_usec) * std.time.ns_per_us);
                },
                std.os.CLOCK_MONOTONIC => {
                    var info: std.os.darwin.mach_timebase_info_data = undefined;
                    std.os.darwin.mach_timebase_info(&info);
                    var counter = std.os.darwin.mach_absolute_time();
                    if (info.numer > 1)
                        counter *= info.numer;
                    if (info.denom > 1)
                        counter /= info.denom;
                    return counter;
                },
                else => unreachable,
            }
        }

        var ts: std.os.timespec = undefined;
        std.os.clock_gettime(clock, &ts) catch return 0;
        return (@intCast(u64, ts.tv_sec) * std.time.ns_per_s) + @intCast(u64, ts.tv_nsec);
    }
};

const LinuxEvent = struct {
    state: State = .unset,

    const Self = @This();
    const State = enum(i32) {
        unset = 0,
        set,
    };

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn set(self: *Self) void {
        @atomicStore(State, &self.state, .set, .Release);

        switch (std.os.linux.getErrno(std.os.linux.futex_wake(
            @ptrCast(*const i32, &self.state),
            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAKE,
            1,
        ))) {
            0 => {},
            std.os.EINVAL => {},
            std.os.EACCES => {},
            std.os.EFAULT => {},
            else => unreachable,
        }
    }

    pub fn wait(self: *Self, timeout: ?u64) bool {
        var deadline: ?u64 = null;
        while (true) {
            if (@atomicLoad(State, &self.state, .Acquire) == .set)
                return true;

            var ts: std.os.timespec = undefined;
            var ts_ptr: ?*std.os.timespec = null;

            if (timeout) |timeout_ns| {
                const delay_ns = delay: {
                    std.os.clock_gettime(std.os.CLOCK_MONOTONIC, &ts) catch return false;
                    const now_ns = (@intCast(u64, ts.tv_sec) * std.time.ns_per_s) + @intCast(u64, ts.tv_nsec);
                    if (deadline) |deadline_ns| {
                        if (now_ns >= deadline_ns)
                            return false;
                        break :delay (deadline_ns - now_ns);
                    } else {
                        deadline = now_ns + timeout_ns;
                        break :delay timeout_ns;
                    }
                };

                ts_ptr = &ts;
                ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), @divFloor(delay_ns, std.time.ns_per_s));
                ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), @mod(delay_ns, std.time.ns_per_s));
            }

            switch (std.os.linux.getErrno(std.os.linux.futex_wait(
                @ptrCast(*const i32, &self.state),
                std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAIT,
                @enumToInt(State.unset),
                ts_ptr,
            ))) {
                0 => {},
                std.os.EINTR => {},
                std.os.EAGAIN => {},
                std.os.ETIMEDOUT => return false,
                else => unreachable,
            }
        }
    }    
};

const Thread = if (std.builtin.os.tag == .windows)
    WindowsThread
else if (std.builtin.link_libc)
    PosixThread
else if (std.builtin.os.tag == .linux)
    LinuxThread
else
    @compileError("Unimplemented Thread primitive for platform");

const WindowsThread = struct {
    handle: std.os.windows.HANDLE,

    const Self = @This();

    pub fn spawn(stack_size: usize, context: anytype, comptime entryFn: anytype) !Self {
        const Context = @TypeOf(context);
        const Wrapper = struct {
            fn entry(raw_arg: std.os.windows.LPVOID) callconv(.C) std.os.windows.DWORD {
                entryFn(@ptrCast(Context, @alignCast(@alignOf(Context), raw_arg)));
                return 0;
            }
        };
        
        const handle = std.os.windows.kernel32.CreateThread(
            null,
            stack_size,
            Wrapper.entry,
            @ptrCast(std.os.windows.LPVOID, context),
            0,
            null,
        ) orelse return error.SpawnError;

        return Self{ .handle = handle };
    }

    pub fn join(self: Self) void {
        std.os.windows.WaitForSingleObjectEx(self.handle, std.os.windows.INFINITE, false) catch unreachable;
        std.os.windows.CloseHandle(self.handle);
    }
};

const PosixThread = struct {
    handle: std.c.pthread_t,

    const Self = @This();

    pub fn spawn(stack_size: usize, context: anytype, comptime entryFn: anytype) !Self {
        const Context = @TypeOf(context);
        const Wrapper = struct {
            fn entry(raw_arg: ?*c_void) callconv(.C) ?*c_void {
                entryFn(@ptrCast(Context, @alignCast(@alignOf(Context), raw_arg)));
                return null;
            }
        };

        var attr: std.c.pthread_attr_t = undefined;
        if (std.c.pthread_attr_init(&attr) != 0)
            return error.SystemResources;
        defer std.debug.assert(std.c.pthread_attr_destroy(&attr) == 0);
        if (std.c.pthread_attr_setstacksize(&attr, stack_size) != 0)
            return error.SystemResources;

        var handle: std.c.pthread_t = undefined;
        const rc = std.c.pthread_create(
            &handle,
            &attr,
            Wrapper.entry,
            @ptrCast(?*c_void, context),
        );

        return switch (rc) {
            0 => Self{ .handle = handle },
            else => error.SpawnError,
        };
    }

    pub fn join(self: Self) void {
        const rc = std.c.pthread_join(self.handle, null);
        std.debug.assert(rc == 0);
    }
};

const LinuxThread = struct {
    info: *Info,

    const Self = @This();
    const Info = struct {
        mmap_ptr: usize,
        mmap_len: usize,
        context: usize,
        handle: i32,
    };

    pub fn spawn(stack_size: usize, context: anytype, comptime entryFn: anytype) !Self {
        var mmap_size: usize = std.mem.page_size;
        const guard_end = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size + stack_size, std.mem.page_size);
        const stack_end = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size, @alignOf(Info));
        const info_begin = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size + @sizeOf(Info), std.os.linux.tls.tls_image.alloc_align);
        const tls_begin = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size + std.os.linux.tls.tls_image.alloc_size, std.mem.page_size);

        const mmap_bytes = try std.os.mmap(
            null,
            mmap_size,
            std.os.PROT_NONE,
            std.os.MAP_PRIVATE | std.os.MAP_ANONYMOUS,
            -1,
            0,
        );
        errdefer std.os.munmap(mmap_bytes);

        try std.os.mprotect(
            mmap_bytes[guard_end..],
            std.os.PROT_READ | std.os.PROT_WRITE,
        );

        const info = @ptrCast(*Info, @alignCast(@alignOf(Info), &mmap_bytes[info_begin]));
        info.* = .{
            .mmap_ptr = @ptrToInt(mmap_bytes.ptr),
            .mmap_len = mmap_bytes.len,
            .context = @ptrToInt(context),
            .handle = undefined,
        };

        var user_desc: switch (std.builtin.arch) {
            .i386 => std.os.linux.user_desc,
            else => void,
        } = undefined;

        var tls_ptr = std.os.linux.tls.prepareTLS(mmap_bytes[tls_begin..]);
        if (std.builtin.arch == .i386) {
            defer tls_ptr = @ptrToInt(&user_desc);
            user_desc = .{
                .entry_number = std.os.linux.tls.tls_image.gdt_entry_number,
                .base_addr = tls_ptr,
                .limit = 0xfffff,
                .seg_32bit = 1,
                .contents = 0,
                .read_exec_only = 0,
                .limit_in_pages = 1,
                .seg_not_present = 0,
                .useable = 1,
            };
        }

        const flags: u32 = 
            std.os.CLONE_SIGHAND | std.os.CLONE_SYSVSEM |
            std.os.CLONE_VM | std.os.CLONE_FS | std.os.CLONE_FILES |
            std.os.CLONE_PARENT_SETTID | std.os.CLONE_CHILD_CLEARTID |
            std.os.CLONE_THREAD | std.os.CLONE_DETACHED | std.os.CLONE_SETTLS;

        const Context = @TypeOf(context);
        const Wrapper = struct {
            fn entry(raw_arg: usize) callconv(.C) u8 {
                const info_ptr = @intToPtr(*Info, raw_arg);
                entryFn(@intToPtr(Context, info_ptr.context));
                return 0;
            }
        };

        const rc = std.os.linux.clone(
            Wrapper.entry,
            @ptrToInt(&mmap_bytes[stack_end]),
            flags,
            @ptrToInt(info),
            &info.handle,
            tls_ptr,
            &info.handle, 
        );

        return switch (std.os.linux.getErrno(rc)) {
            0 => Self{ .info = info },
            else => error.SpawnError,
        };
    }

    pub fn join(self: Self) void {
        while (true) {
            const tid = @atomicLoad(i32, &self.info.handle, .SeqCst);
            if (tid == 0) {
                std.os.munmap(@intToPtr([*]align(std.mem.page_size) u8, self.info.mmap_ptr)[0..self.info.mmap_len]);
                return;
            }

            const rc = std.os.linux.futex_wait(&self.info.handle, std.os.linux.FUTEX_WAIT, tid, null);
            switch (std.os.linux.getErrno(rc)) {
                0 => continue,
                std.os.EINTR => continue,
                std.os.EAGAIN => continue,
                else => unreachable,
            }
        }
    }
};

pub fn main() !void {
    const FibRecurse = struct {
        fn call(allocator: *std.mem.Allocator, _n: usize) anyerror!void {
            var n = _n;
            if (n <= 1) 
                return;

            suspend {
                var task = Loop.Task.init(@frame());
                Loop.schedule(&task, .High);
            }

            var tasks = std.ArrayList(*@Frame(@This().call)).init(allocator);
            defer tasks.deinit();

            var err: ?anyerror = null;
            while (n > 1) {
                const f = allocator.create(@Frame(@This().call)) catch |e| {
                    err = e;
                    break;
                };
                tasks.append(f) catch |e| {
                    err = e;
                    break;
                };
                f.* = async @This().call(allocator, n - 2);
                n = n - 1;
            }

            for (tasks.items) |frame| {
                (await frame) catch |e| {
                    if (err == null)
                        err = e;
                };
            }

            return err orelse {};
        }
    };

    const FibNaive = struct {
        fn call(allocator: *std.mem.Allocator, n: usize) anyerror!usize {
            if (n <= 1) 
                return n;

            suspend {
                var task = Loop.Task.init(@frame());
                Loop.schedule(&task, .High);
            }

            const l = try allocator.create(@Frame(@This().call));
            defer allocator.destroy(l);

            const r = try allocator.create(@Frame(@This().call));
            defer allocator.destroy(r);

            l.* = async @This().call(allocator, n - 1);
            r.* = async @This().call(allocator, n - 2);

            const lv = await l;
            const rv = await r;

            const lc = try lv;
            const rc = try rv;
            return (lc + rc);
        }
    };

    const Fib = FibNaive;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var win_heap = if (std.builtin.os.tag == .windows) std.heap.HeapAllocator.init() else {};
    const allocator = if (std.builtin.link_libc)
        std.heap.c_allocator
    else if (std.builtin.os.tag == .windows)
        &win_heap.allocator
    else
        &gpa.allocator;

    _ = try (try Loop.run(.{}, Fib.call, .{allocator, 30}));
}