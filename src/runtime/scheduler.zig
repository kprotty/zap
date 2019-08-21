const std = @import("std");
const builtin = @import("builtin");

const os = struct {
    pub const io = @import("io.zig");
    pub const sync = @import("sync.zig");
    pub const thread = @import("thread.zig");
};

pub const Config = struct {
    max_workers: ?usize,
    max_threads: ?usize,
    allocator: ?*std.mem.Allocator,

    pub fn default() Config {
        return Config {
            .allocator = null,
            .max_threads = null,
            .max_workers = null,
        };
    }
};

// note: Store nodes on the task stack itself for submission
// note: file per os rewrite. Fixed fs thread limit also
// note: dont take in an allocator, use mmap/virtualmalloc it all 
pub var system: System = undefined;
pub const System = struct {
    allocator: *std.mem.Allocator,
    selector: os.io.Selector,

    workers: ?[]Worker,
    main_worker: Worker,
    run_queue: Worker.GlobalTaskQueue,

    max_threads: usize,
    main_thread: Thread,
    idle_threads: os.sync.AtomicStack(Thread, "link"),

    main_task: Task,
    live_tasks: os.sync.Futex,

    pub fn run(self: *@This(), config: Config, comptime function: var, args: ...) !void {
        // initialize thread data
        self.idle_threads.init();
        self.live_threads.init(0);
        self.max_threads = if (builtin.single_threaded) 1 else std.math.max(1, config.max_threads orelse 1 << 16);
        
        // initialize worker data
        self.run_queue.init();
        self.allocator = config.allocator orelse std.heap.direct_allocator; // TODO: find better default
        const num_workers = std.math.min(self.max_threads, std.math.max(1, config.max_workers orelse os.thread.cpuCount()));
        self.workers = if (num_workers > 1) try self.allocator.alloc(Worker, num_workers) else null;
        defer if (self.workers) |workers| self.allocator.free(workers);
        if (self.workers) |workers| for (workers) |*w| w.init();
        self.main_worker.init();

        // register the current task on the main_thread
        Thread.current = &self.main_thread;
        defer Thread.current = null;
        // TODO
    }
};

pub const Task = struct {
    id: u32,
    delay: u32,
    link: ?*Task,
    next: ?*Task,
    prev: ?*Task,
    frame: anyframe,
};

pub const Thread = struct {
    pub threadlocal var current: ?*Thread = undefined;

    link: ?*@This(),
    task: ?*Task,
    worker: *Worker,
    futex: os.sync.Futex,

    pub fn init(self: *@This(), worker: *Worker) void {
        self.link = null;
        self.task = null;
        self.futex.init(0);
        self.worker = worker;
        self.worker.thread = self;
    }

    pub fn run(self: *@This(), worker: *Worker, task: *Task) void {
        self.init(worker);
        self.worker.run_queue.put(task);
        
        // TODO: run worker's tasks
    }
};

pub const Worker = struct {
    thread: ?*Thread,
    run_queue: LocalTaskQueue,
    delayed_queue: DelayedQueue,

    pub fn init(self: *@This()) void {
        self.thread = null;
        self.run_queue.init();
    }

    pub const LocalTaskQueue = struct {
        head: u32,
        tail: u32,
        tasks: [256]*Task,

        pub fn init(self: *@This()) void {
            self.head = 0;
            self.tail = 0;
        }

        pub fn put(self: *@This(), task: *Task) void {

        }
    };

    pub const GlobalTaskQueue = struct {
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
    };

    /// Pairing heap: https://github.com/sray256/pairing-heap/blob/master/heap.c
    pub const DelayedQueue = struct {
        top: ?*Task,

        pub fn init(self: *@This()) void {
            self.top = null;
        }

        pub fn peek(self: *@This()) ?*Task {
            return self.top;
        }

        pub fn put(self: *@This(), task: *Task) void {
            task.link = null;
            task.next = null;
            task.prev = null;
            self.top = if (self.top) |top| merge(task, top) else task;
        }

        pub fn get(self: *@This()) ?*Task {
            const top = self.top orelse return null;
            if (top.link) |link| {
                link.prev = null;
                self.top = mergeLeft(mergeRight(link));
            } else self.top = null;
            return top;
        }

        fn mergeLeft(link: *Task) *Task {
            var top = link.prev;
            var task = link;
            while (top) |top_task| {
                task = merge(top_task, task);
                top = task.prev;
            }
            return task;
        }

        fn mergeRight(link: *Task) *Task {
            var top = link;
            var task = link;
            while (top) |top_task| {
                task = merge(top_task, top_task.next orelse return top_task);
                top = task.next;
            }
            return task;
        }

        fn merge(left: *Task, right: *Task) *Task {
            var l = left;
            var r = right;
            if (l.state >= r.state) {
                const temp = l;
                l = r;
                r = temp;
            }
            if (l.link) |link| link.prev = r;
            if (r.link) |link| link.prev = l;
            l.next = r.next;
            r.next = l.link;
            l.link = r;
            r.prev = l;
            return l;
        }
    }
};