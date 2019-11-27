const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const platform = switch (builtin.os) {
    .windows => @import("platform/windows.zig"),
    .linux => @import("platform/linux.zig"),
    else => @import("platform/unix.zig"),
};

pub const Executor = struct {
    const instance = std.event.Loop.instance orelse 
        @compileError("A valid executor is required");

    allocator: ?*std.mem.Allocator,
    workers: []Worker,
    active_tasks: usize,
    idle_workers: ?*Worker,
    stop_event: std.ResetEvent,

    runq_lock: std.Mutex,
    runq_size: usize,
    runq_head: ?*Task,
    runq_tail: ?*Task,

    thread_lock: std.Mutex,
    idle_threads: ?*Thread,
    free_threads: usize,
    monitor_thread: ?*Thread,
    monitor_tick: u64,

    pub fn init(self: *Executor) !void {
        if (builtin.single_threaded)
            return self.initSingleThreaded();
        
        const max_threads = 1024;
        const max_workers = try std.Thread.cpuCount();
        return self.initMultiThreaded(max_workers, max_threads);
    }

    pub fn initSingleThreaded(self: *Executor) !void {
        return self.initUsing(@as([*]Worker, undefined)[0..0], 1, null);
    }

    pub fn initMultiThreaded(self: *Executor, max_workers: usize, max_threads: usize) !void {
        const num_threads = std.math.max(1, max_threads);
        const num_workers = std.math.min(num_threads, std.math.max(1, max_workers));
        if (num_threads == 1)
            return self.initSingleThreaded();

        // TODO: Use a better allocator
        const allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.direct_allocator;
        const workers = try allocator.alloc(Worker, num_workers);
        return self.initUsing(workers, num_threads, allocator);
    }

    pub fn initUsing(self: *Executor, workers: []Worker, max_threads: usize, allocator: ?*std.mem.Allocator) !void {
        self.* = Executor{
            .allocator = allocator,
            .workers = workers,
            .active_tasks = 0,
            .idle_workers = null,
            .stop_event = std.ResetEvent.init(),
            .runq_lock = std.Mutex.init(),
            .runq_size = 0,
            .runq_head = null,
            .runq_tail = null,
            .thread_lock = std.Mutex.init(),
            .idle_threads = null,
            .free_threads = max_threads,
            .monitor_thread = null,
            .monitor_tick = 0,
        };
        for (workers) |*worker| {
            worker.* = Worker.init();
            self.idle_workers = worker;
        }
    }

    pub fn deinit(self: *Executor) void {
        self.stop_event.deinit();
        self.runq_lock.deinit();
        self.thread_lock.deinit();
        if (self.allocator) |allocator| {
            allocator.free(self.workers);
        }
    }

    // dummy functions to keep start.zig happy
    pub fn beginOneEvent(self: *Executor) void {}
    pub fn finishOneEvent(self: *Executor) void {}

    pub fn run(self: *Executor) void {
        // get an idle worker or use one from the stack in single threaded mode
        self.free_threads -= 1;
        const main_worker = self.idle_workers orelse {
            self.workers = ([_]Worker{ Worker.init() })[0..];
            return Thread.run(&self.workers[0]);
        };

        // run the main_worker and wait for the stop_event to be set
        self.idle_workers = main_worker.next;
        Thread.run(main_worker);
        _ = self.stop_event.wait(null);

        // wait for the monitor thread to exit if there is one
        if (self.monitor_thread) |monitor_thread| {
            _ = monitor_thread.worker_event.set(false);
            monitor_thread.handle.join();
        }

        // wait for all the idle threads to exit
        const held = self.thread_lock.acquire();
        defer held.release();
        var idle_threads = self.idle_threads;
        while (idle_threads) |thread| {
            thread.wakeWith(Thread.EXIT_WORKER);
            idle_threads = thread.next;
        }
        while (self.idle_threads) |thread| {
            thread.handle.join();
            self.idle_threads = thread.next;
        }
    }

    fn setIdleThread(self: *Executor, thread: *Thread) void {
        const held = self.thread_lock.acquire();
        defer held.release();

        thread.next = self.idle_threads;
        self.idle_threads = thread;
    }

    fn spawnThread(self: *Executor, worker: *Worker) std.Thread.SpawnError!void {
        const held = self.thread_lock.acquire();
        defer held.release();

        // try using a thread in the free list
        if (self.idle_threads) |idle_thread| {
            const thread = idle_thread;
            self.idle_threads = thread.next;
            thread.wakeWith(worker);
            return;
        }

        // free list is empty, try and spawn a new thread
        if (self.free_threads == 0)
            return std.Thread.SpawnError.ThreadQuotaExceeded;
        self.free_threads -= 1;
        platform.Thread.spawn(worker, Thread.run) catch |err| {
            self.free_threads = 0; // assume hit thread limit on error
            return err;
        };
    }

    pub fn yield() void {
        const thread = Thread.current orelse return;
        return thread.worker.yield();
    }

    pub fn blocking(self: *Executor, comptime func: var, args: ...) @typeOf(func).ReturnType {
        const thread = Thread.current orelse return func(args);
        return thread.worker.blocking(func, args);
    }

    fn hasPendingTasks(self: *const Executor) bool {
        if (builtin.single_threaded)
            return self.active_tasks > 0;
        return @atomicLoad(usize, &self.active_tasks, .Acquire) > 0;
    }

    fn finishTask(self: *Executor) bool {
        if (!builtin.single_threaded)
            return @atomicRmw(usize, &self.active_tasks, .Sub, 1, .Release) == 1;
        const previous = self.active_tasks;
        self.active_tasks -= 1;
        return previous == 1;
    }
};

const Thread = struct {
    threadlocal var current: ?*Thread = null;

    next: ?*Thread,
    worker: *Worker,
    handle: platform.Thread,
    worker_event: std.ResetEvent,

    const EXIT_WORKER = @intToPtr(*Worker, 0x1);
    const MONITOR_WORKER = @intToPtr(*Worker, 0x2);

    fn wakeWith(self: *Thread, worker: *Worker) void {
        self.worker = worker;
        _ = self.worker_event.set(true);
    }

    fn run(worker: *Worker) void {
        var self = Thread{
            .next = null,
            .worker = worker,
            .handle = undefined,
            .worker_event = std.ResetEvent.init(),
        };
        self.handle.getCurrent();
        defer self.worker_event.deinit();
        Thread.current = &self;

        while (self.worker != EXIT_WORKER) {
            if (self.worker == MONITOR_WORKER)
                return self.monitor();
            self.worker.run(self);

            Executor.instance.setIdleThread(self);
            _ = self.worker_event.wait(null);
            assert(self.worker_event.reset());
        }
    }

    fn monitor(self: *Thread) void {
        // TODO
    }
};

const Worker = struct {
    runq_head: u32,
    runq_tail: u32,
    runq: [256]*Task,
    runq_tick: usize,
    runq_next: ?*Task,

    next: ?*Worker,
    thread: ?*Thread,
    monitor_tick: u64,

    fn init() Worker {
        return Worker{
            .runq_head = 0,
            .runq_tail = 0,
            .runq = undefined,
            .runq_tick = 0,
            .runq_next = null,
            .next = self.idle_workers,
            .thread = null,
            .monitor_tick = 0,
        };
    }

    fn run(self: *Worker, thread: *Thread) void {
        self.thread = thread;
        const executor = Executor.instance;

        while (executor.hasPendingTasks()) {
            resume self.getTask().getFrame();
            if (executor.finishTask()) {
                _ = executor.stop_event.set(false);
                return;
            }
        }
    }

    fn getTask(self: *Worker) *Task {
        self.runq_tick +%= 1;
        const executor = &Executor.current;
        
        // check the global queue once in a while
        if (self.runq_tick % 61 == 0 and @atomicLoad(usize, &executor.runq_size, .Monotonic) > 0) {
            if (executor.getTasks(self, 1)) |task|
                return task;
        }

        // try pop from the local queue (pop from the back once in a while for fairness)
        if (self.pop()) |task| {
            return task;
        }

        // local queue is empty, try and pop from the global queue
        if (@atomicLoad(usize, &executor.runq_size, .Monotonic) > 0) {
            if (executor.getTasks(self, null)) |task|
                return task;
        }


    }

    fn pop(self: *Worker) ?*Task {        
        while (true) : (std.SpinLock.yield(1)) {
            const head = @atomicLoad(u32, &self.runq_head, .Acquire);
            const tail = self.runq_tail;
            if (tail == head)
                return null;
            const task = self.runq[head % self.runq.len];
            _ = @cmpxchgWeak(u32, &self.runq_head, head, head +% 1, .Release, .Monotonic) orelse return task;
        }
    }

    fn steal(self: *Worker, other: *Worker, steal_next: bool) u32 {
        while (true) : (std.SpinLock.yield(1)) {
            const head = @atomicLoad(u32, &other.runq_head, .Acquire);
            const tail = @atomicLoad(u32, &other.runq_tail, .Acquire);
            var size = tail -% head;
            size = size - (size / 2);
            
            if (size == 0) {
                if (!steal_next)
                    return 0;
                const next = @atomicLoad(?*Task, &other.runq_next, .Monotonic) orelse return 0;
            }
        }
    }
};

pub const Task = struct {
    next: ?*Task,
    frame: usize,

    pub const Priority = enum(u1) {
        Low,
        High,
    };

    pub fn init(frame: anyframe, comptime priority: Priority) Task {
        return Task{
            .next = null,
            .frame = @ptrToInt(frame) | @enumToInt(priority);
        };
    }

    pub fn getFrame(self: Task) anyframe {
        return @intToPtr(frame, self.frame & ~@as(usize, ~@as(@TagType(Priority), 0)));
    }

    pub fn getPriority(self: Task) Priority {
        return @intToEnum(Priority, @as(@TagType(Priority), self.frame & ~FRAME_MASK));
    }
};
