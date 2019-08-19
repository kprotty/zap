const std = @import("std");
const builtin = @import("builtin");

const os = struct {
    pub const sync = @import("sync.zig");
    pub const thread = @import("thread.zig");
};

pub const Config = struct {
    max_workers: ?usize,
    max_threads: ?usize,
    allocator: *std.mem.Allocator,

    pub fn default() Config {
        return Config {
            .allocator = null,
            .max_threads = null,
            .max_workers = null,
        };
    }
};

pub var system: System = undefined;
pub const System = struct {
    lock: os.sync.Mutex,
    allocator: *std.mem.Allocator,

    workers: []Worker,
    run_queue: Worker.GlobalQueue,
    idle_workers: os.sync.AtomicStack(Worker, "link"),

    max_threads: usize,
    active_threads: usize,
    spinning_threads: usize,
    monitor_thread: ?Thread,
    idle_threads: os.sync.AtomicStack(Thread, "link"),

    pub inline fn isUniCore(self: *@This()) bool {
        return builtin.single_threaded or self.workers.len == 1;
    }

    pub fn run(self: *@This(), config: Config, comptime function: var, args: ...) !void {
        // init thread info
        self.idle_threads.init();
        self.active_threads = 0;
        self.spinning_threads = 0;
        self.monitor_thread = null;
        self.max_threads = if (builtin.single_threaded) 1 else std.math.max(1, config.max_threads orelse (1 << 16));
        
        // init worker info
        self.lock.init();
        self.run_queue.init();
        self.idle_workers.init();
        self.allocator = config.allocator orelse std.heap.direct_allocator; // TODO: use better default

        // allocate & initialize worker array using SmallVec-like optimization
        var stack_workers: [1]Worker = undefined;
        const num_workers = std.math.min(self.max_threads, std.math.max(1, config.max_workers orelse os.thread.cpuCount()));
        self.workers = if (builtin.single_threaded or num_workers == 1) stack_workers[0..] else try self.allocator.alloc(Worker, num_workers); 
        defer { if (self.workers.len > 1) self.allocator.free(self.workers); }
        for (self.workers) |*worker| {
            worker.init();
            self.idle_workers.put(worker);
        }

        // start the main_task on the main_thread
        var main_thread: Thread = undefined;
        var main_task = Task { .link = null, .frame = undefined };
        main_thread.init(self.idle_workers.get().?, &main_task);
        Thread.current = &main_thread;
        main_task.frame = async function(args);
        main_thread.run();
    }
};

pub const Task = struct {
    link: ?*Task,
    frame: anyframe,
};

pub const Thread = struct {
    pub threadlocal var current: ?*Thread = null;

    link: ?*Thread,
    task: *Task,
    worker: *Worker,

    pub fn init(self: *@This(), worker: *Worker, task: *Task) void {
        self.link = null;
        self.task = task;
        self.worker = worker;
    }

    pub fn run(self: *@This()) void {
        current = self;
        var inherit_time: bool = undefined;

        while (self.findRunnable(&inherit_time)) |task| {
            self.task = task;
            resume task.frame;
        }
    }

    fn findRunnable(self: *@This(), inherit_time: *bool) ?*Task {
        while (true) {
            // local run queue
            if (self.worker.run_queue.get(inherit_time)) |task|
                return task;
            inherit_time.* = false;

            // global run queue
            if (system.run_queue.get()) |task|
                return task;

            // netpoll(non blocking)

            // Prepare to steal from other workers.
            // Returns null if either max_workers=1 or all other workers are idle.
            // New tasks can be added from syscall stealing, network polling or timers.
            // None submit tasks to the local run_queue of workers, so no point in stealing
            const num_workers = system.workers.len;
            if (@atomicLoad(usize, &system.idle_workers.count, .Acquire) == num_workers - 1)
                return null;

            // If number of spinning threads >= number of busy workers, block.
            // This is to prevent excessive CPU consumptions on max_workers > 1 with low parallelism
            const idle_workers = @atomicLoad(usize, &system.idle_workers.count, .Acquire);
            const spinning_threads = @atomicLoad(usize, &system.spinning_threads, .Monotonic);
            if (2 * spinning_threads >= num_workers - idle_workers)
                return null;

            // Start spinning and try to steal tasks from other Workers
            _ = @atomicRmw(usize, &system.spinning_threads, .Add, 1, .AcqRel);
            // for x in steal
        }
};

pub const Worker = struct {

    link: ?*Worker,
    run_queue: LocalQueue,

    pub const LocalQueue = struct {
        head: usize,
        tail: usize,
        next: ?*Task,
        tasks: [256]*Task,

        pub fn init(self: *@This()) void {
            self.head = 0;
            self.tail = 0;
            self.next = null;
        }

        pub fn isEmpty(self: *@This()) bool {
            return false; // TODO
        }

        pub fn get(self: *@This(), inherit_time: *bool) ?*Task {
            return null; // TODO
        }
    };

    pub const GlobalQueue = struct {
        head: ?*Task,
        tail: ?*Task,
        count: usize,
        lock: os.sync.Mutex,

        pub fn init(self: *@This()) void {
            self.count = 0;
            self.head = null;
            self.tail = null;
            self.lock.init();
        }

        pub fn get(self: *@This()) ?*Task {
            if (self.count == 0) return null;
            self.lock.acquire();
            defer self.lock.release();

        }
    };
};