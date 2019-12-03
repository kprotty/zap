const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const Loop = struct {
    lock: std.Mutex,
    coprime: usize,
    pending_tasks: usize,
    stop_event: std.ResetEvent,
    allocator: ?*std.mem.Allocator,

    workers: []Worker,
    idle_worker: ?*Worker,
    spinning_workers: usize,
    run_queue: Task.List,

    max_threads: usize,
    free_threads: usize,
    idle_thread: ?*Thread,
    monitor_thread: ?*Thread,
    monitor_timer: std.time.Timer,

    pub fn init(self: *Loop) !void {
        if (builtin.single_threaded)
            return self.initSingleThreaded();
        return self.initMultiThreaded();
    }

    pub fn initSingleThreaded(self: *Loop) !void {
        return self.initUsing(1, 1);
    }

    pub fn initMultiThreaded(self: *Loop) !void {
        const thread_count = 10000; // default in golang, rust-tokio and rust-async_std
        const cpu_count = try std.Thread.cpuCount();
        return self.initUsing(cpu_count, thread_count);
    }

    pub fn initUsing(self: *Loop, max_workers: usize, max_threads: usize) !void {
        self.* = Loop{
            .lock = std.Mutex.init(),
            .coprime = undefined,
            .pending_tasks = 0,
            .stop_event = std.ResetEvent.init(),
            .allocator = null,
            .workers = @as([*]Worker, undefined)[0..0],
            .idle_worker = null,
            .spinning_workers = 0,
            .run_queue = Task.List{
                .head = null,
                .tail = null,
                .size = 0,
            },
            .max_threads = max_threads,
            .free_threads = max_threads,
            .idle_thread = null,
            .monitor_thread = null,
            .monitor_timer = try std.time.Timer.start(),
        };

        // allocate the workers if multi-threaded
        if (max_workers > 1) {
            const allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.direct_allocator;
            self.workers = try allocator.alloc(Worker, max_workers);
            self.allocator = allocator;
            for (self.workers) |*worker| {
                worker.* = Worker.init(self);
                self.setIdleWorker(worker);
            }
        }
    }

    pub fn deinit(self: *Loop) void {
        if (self.allocator) |allocator|
            allocator.free(self.workers);
        self.stop_event.deinit();
        self.lock.deinit();
        self.* = undefined;
    }

    pub fn run(self: *Loop) void {
        if (self.allocator != null)
            return self.runLoop();

        // allocate a worker on the stack if only 1 to avoid heap alloc on single-threaded
        var workers = [_]Worker{ Worker.init(self) };
        self.workers = workers[0..];
        self.setIdleWorker(&workers[0]);
        return self.runLoop();
    }

    fn runLoop(self: *Loop) void {
        // initialization which depends on number of workers
        if (!builtin.single_threaded and self.workers.len > 1)
            self.coprime = RandomIterator.getCoprime(self.workers.len);
        
        // run the main worker on the main thread & wait for stop_event
        const main_worker = self.getIdleWorker() orelse return;
        self.free_threads -= 1;
        Thread.start(tagged(main_worker, Thread.Action.Run));
        if (!builtin.single_threaded)
            _ = self.stop_event.wait(null) catch unreachable;
    }

    fn stopLoop(self: *Loop) void {
        // grab them all in one swoop
        const held = self.lock.acquire();
        var idle_threads = self.idle_thread;
        self.idle_thread = null;
        held.release();

        // send the exit signal & wake them up
        while (idle_threads) |thread| {
            defer idle_threads = thread.next;
            thread.worker = null;
            _ = thread.worker_event.set(false);
        }
    }

    /// Call a function which may block the event loop.
    pub fn blocking(self: *Loop, comptime blockingFn: var, args: ...) @typeOf(blockingFn).ReturnType {
        // try and transition into a blocking state
        var current_thread = if (builtin.single_threaded) null else Thread.current;
        if (current_thread) |thread| {
            if (!thread.startBlocking())
                current_thread = null;
        }

        // at the end, transition out of a blocking state if it was
        defer if (current_thread) |thread| {
            thread.stopBlocking();
        };

        // perform the blocking action
        return blockingFn(args);
    }

    /// Should be called anywhere before or after a function suspends
    pub fn beginSuspend(self: *Loop) void {
        _ = atomicRmw(&self.pending_tasks, .Add, 1, .Acquire);
    }

    fn hasPendingTasks(self: *const Loop) bool {
        return atomicLoad(&self.pending_tasks, .Monotonic) != 0;
    }
    
    /// Let the event loop try and schedule another task
    pub fn yield(self: *Loop) void {
        suspend {
            var task = Task.init(@frame(), .Low);
            self.beginSuspend();
            self.submit(&task);
        }
    }

    /// Push a single task to the global run queue
    fn push(self: *Loop, task: *Task) void {
        const held = self.lock.acquire();
        defer held.release();

        task.next = null;
        self.run_queue.push(Task.List{
            .head = task,
            .tail = task,
            .size = 1,
        });
    }

    fn submit(self: *Loop, task: *Task) void {
        // push to local run queue if theres a running worker thread. if not, push to global run queue
        const thread = Thread.current orelse return self.push(task);
        const worker = getPtr(Thread.Action, thread.worker) orelse return self.push(task);
        worker.run_queue.push(task);

        // if this task is the only one alive, no need to spawn new threads
        if (!worker.hasRunnableTasks())
            return;

        // if theres threads actively spinning for work, let one of them take it
        if (atomicLoad(&self.spinning_workers, .SeqCst) != 0)
            return;

        // try and spawn a new worker to handle this task.
        return self.spawnWorker();
    }

    fn setIdleWorker(self: *Loop, worker: *Worker) void {
        worker.next = self.idle_worker;
        self.idle_worker = worker;
    }

    fn getIdleWorker(self: *Loop) ?*Worker {
        if (!self.hasPendingTasks())
            return null;

        const worker = self.idle_worker orelse return null;
        defer self.idle_worker = worker.next;
        return worker;
    }

    fn spawnWorker(self: *Loop) void {
        // single threaded loops cant spawn workers
        if (builtin.single_threaded or self.workers.len == 1)
            return;

        // no worker should be spinning when spawning a new one
        if (!cmpxchg(.Strong, &self.spinning_workers, 0, 1, .Acquire))
            return;

        const held = self.lock.acquire();
        defer held.release();

        // only pop the worker if spawning the thread was successful
        const worker = self.idle_worker orelse return;
        if (self.spawnThread(tagged(worker, Thread.Action.Spin)))
            assert(self.getIdleWorker() != null);
    }

    fn setIdleThread(self: *Loop, thread: *Thread) void {
        thread.next = self.idle_thread;
        self.idle_thread = thread;
        thread.setStatus(.Idle, .Monotonic);
    }

    fn spawnThread(self: *Loop, worker: *Worker) bool {
        // if the worker was spawned spinning & no thread could be spawned,
        // then its OK to undo the increment and give up
        var spawned_thread = false;
        defer if (!spawned_thread and getTag(Thread.Action, worker) == .Spin) {
            assert(atomicRmw(&self.spinning_workers, .Sub, 1, .Release) == 1);
        };

        // check the thread free list
        if (self.idle_thread) |thread| {
            defer self.idle_thread = thread.next;
            thread.worker = worker;
            assert(thread.getStatus(.Monotonic) == .Idle);
            _ = thread.worker_event.set(false);
            spawned_thread = true;

        // try and spawn a new thread
        } else if (self.free_threads != 0) {
            if (std.Thread.spawn(worker, Thread.start)) |os_thread| {
                self.free_threads -= 1;
                spawned_thread = true;
                
                // make sure to free handles on windows since threads will exit on their own
                if (comptime std.Target.current.isWindows())
                    std.os.windows.CloseHandle(os_thread.handle());
            } else |_| {}
        }

        return spawned_thread;
    }
};

const Thread = struct {
    threadlocal var current: ?*Thread = null;

    next: ?*Thread,
    worker: ?*Worker,
    status: Status align(@alignOf(usize)),
    worker_event: std.ResetEvent,

    const Action = enum(u2) {
        Run,
        Spin,
        Monitor,
    };

    const Status = enum(u2) {
        Idle,
        Running,
        Spinning,
        Blocking,
    };

    inline fn getStatus(self: *const Thread, comptime order: builtin.AtomicOrder) Status {
        return @intToEnum(Status, @truncate(@TagType(Status), atomicLoad(@ptrCast(*const usize, &self.status), order)));
    }

    inline fn setStatus(self: *Thread, status: Status, comptime order: builtin.AtomicOrder) void {
        return atomicStore(@ptrCast(*usize, &self.status), @as(usize, @enumToInt(status)), order);
    }

    fn start(worker: *Worker) void {
        var self = Thread{
            .next = null,
            .worker = worker,
            .status = .Running,
            .worker_event = std.ResetEvent.init(),
        };
        defer self.worker_event.deinit();

        Thread.current = &self;
        return self.run();
    }

    fn run(self: *Thread) void {
        var loop: *Loop = undefined;

        // decrement free_threads when the thread is done
        defer {
            const held = loop.lock.acquire();
            defer held.release();
            loop.free_threads += 1;
            assert(loop.free_threads <= loop.max_threads);

            // if this is the last thread, set the stop_event to signal the loop to end
            if (!builtin.single_threaded and loop.free_threads == loop.max_threads)
                _ = loop.stop_event.set(false);
        }

        while (true) {
            const worker = getPtr(Thread.Action, self.worker orelse return);
            const action = getTag(Thread.Action, self.worker);

            // dispatch the worker based on the thread action
            switch (action) {
                .Monitor => {
                    loop = @ptrCast(*Loop, worker);
                    return self.monitor(loop);
                },
                .Run => {
                    loop = worker.loop;
                    self.setStatus(.Running, .Monotonic);
                },
                .Spin => {
                    loop = worker.loop;
                    self.setStatus(.Spinning, .Monotonic);
                },
            }

            // run tasks using the given worker
            while (Worker.findRunnableTask(loop, self, worker)) |task| {
                // std.debug.warn("{} running task 0x{x}\n", std.Thread.getCurrentId(), @ptrToInt(task));
                resume task.getFrame();
                if (atomicRmw(&loop.pending_tasks, .Sub, 1, .Release) == 1)
                    return loop.stopLoop();
                if (self.getStatus(.Monotonic) == .Blocking)
                    break;
            }

            // make sure theres tasks alive in the system
            if (!loop.hasPendingTasks())
                return;

            // the thread lost its worker, sleep until notified with a new one or exit signal
            const held = loop.lock.acquire();
            loop.setIdleThread(self);
            held.release();
            _ = self.worker_event.wait(null) catch unreachable;
            assert(self.worker_event.reset());
        }
    }

    fn monitor(self: *Thread, loop: *Loop) void {
        // TODO
    }
};

const Worker = struct {
    next: ?*Worker,
    loop: *Loop,
    thread: ?*Thread,
    run_tick: usize,
    run_queue: LocalQueue,

    /// number of atttempts at stealing tasks from other workers in the event loop
    const STEAL_ATTEMPTS = 4;

    /// modulo frequency at which to check the global run queue to avoid global starvation
    const RUN_TICK_GLOBAL = 61;

    fn init(loop: *Loop) Worker {
        return Worker{
            .next = null,
            .loop = loop,
            .thread = null,
            .run_tick = 0,
            .run_queue = LocalQueue{
                .head = 0,
                .tail = 0,
                .tasks = undefined,
            },
        };
    }

    fn hasRunnableTasks(self: *Worker) bool {
        if (!self.run_queue.isEmpty())
            return true;

        if (atomicLoad(&self.loop.run_queue.size, .Monotonic) > 0)
            return true;

        // TODO: check timers
        return false;
    }

    fn findRunnableTask(loop: *Loop, thread: *Thread, runnable_worker: *Worker) ?*Task {
        var worker: ?*Worker = runnable_worker;
        const num_workers = loop.workers.len;

        // this thread may be returning a runnable task so we need to stop spinning.
        defer if (thread.getStatus(.Monotonic) == .Spinning) {
            thread.setStatus(.Running, .Monotonic);
            const spinning = atomicRmw(&loop.spinning_workers, .Sub, 1, .Release);
            assert(spinning <= num_workers);

            // if we're the last thread to come out of spinning with work,
            // try to wake up another worker to guarantee eventual max cpu utilization
            if (spinning == 1)
                loop.spawnWorker();
        };

        lookForWork: while (true) {
            const self = worker orelse return null;
            self.run_tick +%= 1;

            // make sure theres tasks alive in the system
            // std.debug.warn("{} checking active task\n", std.Thread.getCurrentId());
            if (!loop.hasPendingTasks())
                return null;
            
            // check if any task timers expired
            if (self.pollTimers(loop)) |task|
                return task;

            // check the global queue once in a while
            if (self.run_tick % RUN_TICK_GLOBAL == 0) {
                // std.debug.warn("{} checking global queue\n", std.Thread.getCurrentId());
                if (self.pollGlobalQueue(loop, 1, true)) |task|
                    return task;
            }

            // check the local queue
            // std.debug.warn("{} checking local queue\n", std.Thread.getCurrentId());
            if (self.run_queue.pop()) |task|
                return task;

            // check the global queue
            // std.debug.warn("{} checking global queue\n", std.Thread.getCurrentId());
            if (self.pollGlobalQueue(loop, 0, true)) |task|
                return task;

            // check the reactor (block if the only worker, non-blocking otherwise)
            if (pollReactor(loop, null, builtin.single_threaded or loop.workers.len == 1)) |task|
                return task;

            // try and spin (looking for tasks to steal from other workers)
            {
                // if we're the last thread to come out of spinning with work,
                // try to wake up another worker to guarantee eventual max cpu utilization
                const spinning = atomicRmw(&loop.spinning_workers, .Add, 1, .AcqRel);
                defer if (atomicRmw(&loop.spinning_workers, .Sub, 1, .Monotonic) == 1) {
                    loop.spawnWorker();
                };

                // sloppy limit: only spin if less than half the active workers are spinning to decrease contention.
                if (spinning <= num_workers) {
                    thread.setStatus(.Spinning, .Monotonic);
                    defer thread.setStatus(.Running, .Monotonic);

                    // iterate the other workers in the event loop a few times
                    // in a random order and try to steal half of thier tasks
                    var attempt: usize = 0;
                    const rand_seed = loop.monitor_timer.read() ^ @as(u64, @ptrToInt(loop));
                    while (attempt < STEAL_ATTEMPTS) : (attempt += 1) {
                        var rand_iter = RandomIterator.init(loop.coprime, rand_seed, num_workers);
                        while (rand_iter.next()) |index| {
                            const victim = &loop.workers[index];
                            if (victim == self)
                                continue;
                            if (self.run_queue.steal(&victim.run_queue)) |task|
                                return task;
                            // TODO: steal timers?
                        }
                    }
                }
            }

            // check the global queue once more
            {
                if (!loop.hasPendingTasks())
                    return null;
                const held = loop.lock.acquire();
                defer held.release();

                // std.debug.warn("{} checking global queue last time\n", std.Thread.getCurrentId());
                if (self.pollGlobalQueue(loop, 0, false)) |task|
                    return task;

                // if still nothing, give up our worker
                // std.debug.warn("{} no global queue\n", std.Thread.getCurrentId());
                assert(!self.hasRunnableTasks());
                loop.setIdleWorker(self);
                worker = null;
            }

            // thread is transitioning from spinning -> idling.
            // decrement the spinning count first using an AcquireRelease barrier
            // in between before re-checking all the worker queues for tasks.
            // If done the other way around, a thread could submit tasks after
            // we checked all of the queues but before spinning in decremented
            // meaning no one would wake up a thread to run that that task.
            const was_spinning = thread.getStatus(.Monotonic) == .Spinning;
            thread.setStatus(.Idle, .Monotonic);
            if (was_spinning)
                assert(atomicRmw(&loop.spinning_workers, .Sub, 1, .AcqRel) <= num_workers);

            // look for an idle worker with runnable tasks
            for (loop.workers) |*other_worker| {
                if (other_worker == self)
                    continue;
                if (!other_worker.hasRunnableTasks())
                    continue;
                
                // std.debug.warn("{} maybe idle worker\n", std.Thread.getCurrentId());
                const held = loop.lock.acquire();
                const idle_worker = loop.getIdleWorker();
                held.release();

                // we discovered a worker with tasks to be run,
                // store the spinning_workers count as a signal for the defer up-top
                // to try and get another thread spinning this new worker might have steal-able tasks.
                worker = idle_worker orelse break;
                // std.debug.warn("{} found idle worker\n", std.Thread.getCurrentId());
                if (was_spinning) {
                    thread.setStatus(.Spinning, .Monotonic);
                    _ = atomicRmw(&loop.spinning_workers, .Add, 1, .Release);
                } else {
                    thread.setStatus(.Running, .Monotonic);
                }
                continue :lookForWork;
            }

            // last resort: try and poll the reactor (blocking)
            return pollReactor(loop, thread, true);
        }
    }

    fn pollTimers(self: *Worker, loop: *Loop) ?*Task {
        // TODO
        return null;
    }

    fn pollReactor(loop: *Loop, thread: ?*Thread, block: bool) ?*Task {
        // TODO
        return null;
    }

    fn pollGlobalQueue(self: *Worker, loop: *Loop, max: usize, comptime lock: bool) ?*Task {
        // quick atomic check before locking to see if there any tasks to grab
        if (atomicLoad(&loop.run_queue.size, .Monotonic) == 0)
            return null;

        const held = if (lock) loop.lock.acquire() else {};
        defer if (lock) { held.release(); };
        const runq_size = loop.run_queue.size;

        // compute the amount of tasks to grab from the global run queue
        var grab = (runq_size / loop.workers.len) + 1;
        grab = std.math.min(grab, runq_size);
        if (max > 0) grab = std.math.min(grab, max);
        grab = std.math.min(grab, LocalQueue.SIZE);
        atomicStore(&loop.run_queue.size, runq_size - grab, .Monotonic);

        // return the first task in the queue
        const task = loop.run_queue.head.?;
        loop.run_queue.head = task.next;
        grab -= 1;

        // add the rest to the local workers run queue
        while (grab != 0) : (grab -= 1) {
            const t = loop.run_queue.head orelse break;
            self.run_queue.push(t);
            loop.run_queue.head = t.next;
        }
        if (loop.run_queue.head == null)
            loop.run_queue.tail = null;
        return task;
    }

    const LocalQueue = struct {
        head: u32,
        tail: u32,
        tasks: [SIZE]*Task,

        const SIZE = 256;
        const MASK = SIZE - 1;

        const PushType = enum {
            Fifo,
            Lifo,
        };

        fn isEmpty(self: *const LocalQueue) bool {
            const tail = self.tail;
            const head = atomicLoad(&self.head, .Acquire);
            return tail -% head == 0;
        }

        fn push(self: *LocalQueue, task: *Task) void {
            return switch (task.getPriority()) {
                .Low => self.pushQueue(task, .Fifo),
                .Medium => self.pushQueue(task, .Lifo),
                .High => self.pushQueue(task, .Lifo),
            };
        }

        fn pushQueue(self: *LocalQueue, task: *Task, comptime push_type: PushType) void {
            enqueue: while (true) : (std.SpinLock.yield(1)) {
                const tail = self.tail;
                const head = atomicLoad(&self.head, .Acquire);
                
                // local queue isn't full, push to the queue
                if (tail -% head < SIZE) {
                    return switch (push_type) {
                        .Fifo => {
                            self.tasks[tail & MASK] = task;
                            atomicStore(&self.tail, tail +% 1, .Release);
                        },
                        .Lifo => {
                            self.tasks[(head -% 1) & MASK] = task;
                            if (!cmpxchg(.Weak, &self.head, head, head -% 1, .Release))
                                continue :enqueue;
                        },
                    };
                }

                // local queue is full, overflow into the global queue
                if (self.pushOverflow(task, head))
                    return;
            }
        }

        fn pushOverflow(self: *LocalQueue, task: *Task, head: u32) bool {
            // try and grab half the tasks in the local queue
            const move = SIZE / 2;
            if (!cmpxchg(.Weak, &self.head, head, head +% move, .Release))
                return false;

            // create a linked list using the acquired tasks
            var i: u32 = 0;
            while (i < move - 1) : (i += 1) {
                const t = self.tasks[(head +% i) & MASK];
                t.next = self.tasks[(head +% (i + 1)) & MASK];
            }
            self.tasks[(head +% move - 1) & MASK].next = task;
            task.next = null;

            // submit the list of tasks to the global queue
            const loop = @fieldParentPtr(Worker, "run_queue", self).loop;
            const held = loop.lock.acquire();
            defer held.release();
            loop.run_queue.push(Task.List{
                .head = self.tasks[head & MASK],
                .tail = task,
                .size = move + 1,
            });
            return true;
        }

        fn pop(self: *LocalQueue) ?*Task {
            while (true) : (std.SpinLock.yield(1)) {
                const tail = self.tail;
                const head = atomicLoad(&self.head, .Acquire);

                // if the queue is empty, return null.
                if (tail -% head == 0)
                    return null;

                // if not, try and pop a task from the front
                const task = self.tasks[head & MASK];
                if (cmpxchg(.Weak, &self.head, head, head +% 1, .Release))
                    return task;
            }
        }

        fn steal(self: *LocalQueue, other: *LocalQueue) ?*Task {
            // should only try to steal if our local queue is empty
            const t = self.tail;
            const h = atomicLoad(&self.head, .Monotonic);
            assert(t -% h == 0);

            while (true) : (std.SpinLock.yield(1)) {
                // prepare to steal half the tasks from the other queue
                const head = atomicLoad(&other.head, .Acquire);
                const tail = atomicLoad(&other.tail, .Acquire);
                const size = tail -% head;
                var move = size - (size / 2);
                if (move == 0)
                    return null;
                
                // store the other's tasks into our task queue
                var i: u32 = 0;
                while (i < move) : (i += 1) {
                    const task = other.tasks[(head +% i) & MASK];
                    self.tasks[(t +% i) & MASK] = task;
                }

                // try and commit the steal
                if (cmpxchg(.Weak, &other.head, head, head +% move, .Release)) {
                    move -= 1;
                    const task = self.tasks[(t +% move) & MASK];
                    if (move != 0)
                        atomicStore(&self.tail, t +% move, .Release);
                    return task;
                }
            }
        }
    };
};

pub const Task = struct {
    next: ?*Task,
    frame: anyframe,

    pub const Priority = enum(u2) {
        Low,
        Medium,
        High,
    };

    fn init(frame: anyframe, comptime priority: Priority) Task {
        return Task{
            .next = null,
            .frame = tagged(frame, priority),
        };
    }

    fn getFrame(self: Task) anyframe {
        return getPtr(Priority, self.frame);
    }

    fn getPriority(self: Task) Priority {
        return getTag(Priority, self.frame);
    }

    pub const List = struct {
        head: ?*Task,
        tail: ?*Task,
        size: usize,

        pub fn push(self: *List, list: List) void {
            if (self.head == null)
                self.head = list.head;
            if (self.tail) |tail|
                tail.next = list.head;
            self.tail = list.tail;
            atomicStore(&self.size, self.size + list.size, .Monotonic);
        }
    };
};

fn tagged(ptr: var, tag: var) @typeOf(ptr) {
    return @intToPtr(@typeOf(ptr), @ptrToInt(ptr) | @enumToInt(tag));
}

fn getTag(comptime Tag: type, ptr: var) Tag {
    return @intToEnum(Tag, @truncate(@TagType(Tag), @ptrToInt(ptr)));
}

fn getPtr(comptime Tag: type, ptr: var) @typeOf(ptr) {
    return @intToPtr(@typeOf(ptr), @ptrToInt(ptr) & ~@as(usize, ~@as(@TagType(Tag), 0)));
}

fn atomicLoad(ptr: var, comptime order: builtin.AtomicOrder) @typeOf(ptr.*) {
    if (!builtin.single_threaded)
        return @atomicLoad(@typeOf(ptr.*), ptr, order);
    return ptr.*;
}

fn atomicStore(ptr: var, value: @typeOf(ptr.*), comptime order: builtin.AtomicOrder) void {
    if (!builtin.single_threaded)
        return @atomicStore(@typeOf(ptr.*), ptr, value, order);
    ptr.* = value;
}

fn atomicRmw(ptr: var, comptime op: builtin.AtomicRmwOp, value: @typeOf(ptr.*), comptime order: builtin.AtomicOrder) @typeOf(ptr.*) {
    if (!builtin.single_threaded)
        return @atomicRmw(@typeOf(ptr.*), ptr, op, value, order);
    const old = ptr.*;
    ptr.* = switch (op) {
        .Add => old +% value,
        .Sub => old -% value,
        else => unreachable,
    };
    return old;
}

const CmpxchgType = enum{
    Weak,
    Strong,
};

fn cmpxchg(comptime strength: CmpxchgType, ptr: var, cmp: @typeOf(ptr.*), xchg: @typeOf(ptr.*), comptime order: builtin.AtomicOrder) bool {
    if (!builtin.single_threaded) {
        return switch (strength) {
            .Weak => @cmpxchgWeak(@typeOf(ptr.*), ptr, cmp, xchg, order, .Monotonic) == null,
            .Strong => @cmpxchgStrong(@typeOf(ptr.*), ptr, cmp, xchg, order, .Monotonic) == null, 
        };
    }
    if (ptr.* != cmp)
        return false;
    ptr.* = xchg;
    return true;
}

/// Randomly iterate indexes up to `max`
/// https://lemire.me/blog/2017/09/18/visiting-all-values-in-an-array-exactly-once-in-random-order/
const RandomIterator = struct {
    max: usize,
    index: usize,
    coprime: usize,
    rng: std.rand.DefaultPrng,

    fn init(coprime: usize, seed: u64, max: usize) RandomIterator {
        return RandomIterator{
            .max = max,
            .index = max,
            .coprime = coprime,
            .rng = std.rand.DefaultPrng.init(seed),
        };
    }

    fn next(self: *RandomIterator) ?usize {
        if (self.index == 0)
            return null;
        self.index -= 1;
        const offset = self.rng.random.int(usize);
        return ((self.index * self.coprime) + offset) % self.max;
    }

    fn getCoprime(max: usize) usize {
        var i = max - 1;
        var coprime: usize = 0;
        while (i >= max / 2) : (i -= 1) {
            if (gcd(i, max) == 1) {
                coprime = i;
                break;
            }
        }
        return coprime;
    }

    /// Fast way to compute GCD:
    /// https://lemire.me/blog/2013/12/26/fastest-way-to-compute-the-greatest-common-divisor/
    fn gcd(a: usize, b: usize) usize {
        const Shift = @Type(builtin.TypeInfo{
            .Int = builtin.TypeInfo.Int{
                .is_signed = false,
                .bits = @ctz(usize, @typeInfo(usize).Int.bits) - 1,
            },
        });

        var u = a;
        var v = b;
        if (u == 0) return v;
        if (v == 0) return u;
        const shift = @intCast(Shift, @ctz(usize, u | v));
        u >>= @intCast(Shift, @ctz(usize, u));
        while (true) {
            v >>= @intCast(Shift, @ctz(usize, v));
            if (u > v) {
                const t = v;
                v = u;
                u = t;
            }
            v -= u;
            if (v == 0) {
                return u << shift;
            }
        }
    }
};
