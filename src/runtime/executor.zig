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
        // use a global worker instead of heap allocating
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
};

const Thread = struct {
    threadlocal var current: ?*Thread = null;

    next: ?*Thread,
    worker: *Worker,
    handle: platform.Thread,
    worker_event: std.ResetEvent,

    const EXIT_WORKER = @intToPtr(*Worker, 0x1);
    const MONITOR_WORKER = @intToPtr(*Worker, 0x2);

    fn entry(worker: *Worker) void {
        var self = Thread{
            .next = null,
            .worker = worker,
            .handle = undefined,
            .worker_event = std.ResetEvent.init(),
        };
        self.handle.getCurrent();
        defer self.worker_event.deinit();

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

    next: ?*Worker,
    thread: ?*Thread,
    monitor_tick: u64,

    fn init() Worker {
        return Worker{
            .runq_head = 0,
            .runq_tail = 0,
            .runq = undefined,
            .runq_tick = 0,
            .next = self.idle_workers,
            .thread = null,
            .monitor_tick = 0,
        };
    }

    fn run(self: *Worker, thread: *Thread) void {
        self.thread = thread;
        const executor = Executor.instance;
        while (@atomicLoad(usize, executor.active_tasks, .Acquire) > 0) {
            resume self.getTask().getFrame();

            // TODO: blocking tasks

            if (@atomicRmw(usize, executor.active_tasks, .Sub, 1, .Release) == 1) {
                _ = executor.stop_event.set(false);
                return;
            }
        }
    }
};

const Task = struct {
    next: ?*Task,
    frame: anyframe,

    // TODO: priorities

    pub fn getFrame(self: Task) anyframe {
        return self.frame;
    }
};