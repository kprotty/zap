const std = @import("std");
const builtin = @import("builtin");

const os = struct {
    pub const sync = @import("sync.zig");
    pub const thread = @import("thread.zig");
    pub const atomic = @import("atomic.zig");
    pub const heap = @import("heap.zig").Heap;
};

pub const Config = struct {
    max_workers: usize,

    pub fn default() Config {
        return Config {
            .max_workers = os.thread.cpuCount(),
        };
    }
};  

pub const System = struct {
    heap: os.Heap,

    pub fn run(self: *System, config: Config, comptime function: var, args: ...) !void {
        self.heap.init();
        defer self.heap.deinit();

        Thread.init();
        Task.global.init();
        try Worker.init(config);
        defer Worker.deinit();
        
        Worker.all[0].spawn(function, args);
        self.monitor();
    }

    fn monitor(self: *System) void {
        // wait for stop event
    }
};

pub const Worker = struct {
    pub var all: []Worker = undefined;
    pub var num_idle: usize = undefined;
    pub var idle: os.atomic.Queue(Worker, "next") = undefined;

    pub fn init(heap: *os.Heap, config: Config) !void {
        idle.init();
        num_idle = 0;
        all = try heap.allocator.alloc(std.math.max(1, config.max_workers));

        for (all) |*worker| {
            worker.heap.init();
            worker.status = .Idle;
            num_idle += 1;
            idle.push(worker);
        }
    }

    pub fn deinit(heap: *os.Heap) void {
        for (all) |*worker|
            worker.heap.deinit();
        heap.allocator.free(all);
        all = []Worker {};
    }

    status: Status,
    next: ?*Worker,
    heap: os.Heap,
    thread: *Thread,
    run_queue: TaskQueue,

    pub fn spawn(self: *Worker, comptime function: var, args: ...) !void {
        const TaskWrapper = struct {
            async fn func(task_ref: *Task, func_args: ...) void {
                suspend {
                    task_ref.handle = @handle();
                    task_ref.status = .Runnable;
                }
                _ = await (async function(func_args) catch unreachable);
                task_ref.status = .Completed;
            }
        };

        // spawn a new task and increment the active count
        const task = try self.heap.allocator.init(Task);
        _ = try async<allocator> TaskWrapper.func(task, args);
        _ = @atomicRmw(usize, &Task.active, .Add, 1, .Acquire);
        
        // try and place it onto an idle worker for concurrent
        // if theres no idle workers, just add it to the local run queue
        if (idle.pop()) |idle_worker| {
            try Thread.start(idle_worker, task);
        } else {
            self.run_queue.put(task, true);
        }
    }

    pub const Status = enum {
        Idle,
        Running,
        Syscall,
    };

    pub const TaskQueue = struct {
        head: u32,
        tail: u32,
        next: ?*Task,
        tasks: [256]*Task,

        pub fn init(self: *@This()) {
            self.head = 0;
            self.tail = 0;
            self.next = null;
        }

        /// Try and put the new_task in the local run queue.
        /// If as_next, put it in the self.next slot instead.
        /// If the local run queue is full, move half of them to the global run queue.
        pub fn put(self: *@This(), new_task: *Task, as_next: bool) void {
            var task = new_task;

            // if as_next, set to the self.next slot and push the old one to the tasks queue
            if (as_next) {
                var old_next = @atomicLoad(?*Task, &self.next, .Monotonic);
                while (@cmpxchgWeak(?*Task, &self.next, old_next, task)) |current_next|
                    old_next = current_next;
                task = old_next orelse return;
            }

            while (true) {
                // fast path, add one task to the queue
                const head = @atomicLoad(u32, &self.head, .Acquire);
                const tail = self.tail;
                if (head - tail < self.tasks.len) {
                    self.tasks[tail % self.tasks.len] = task;
                    atomic.store(u32, &self.tail, tail + 1, .Monotonic);
                    return;
                }

                // slow path (run_queue is full), try and grab half of the runqueue
                var task_batch: [self.batch.len / 2 + 1]*Task = undefined;
                var batch = task_batch[0 .. (tail - head) / 2];
                if (batch.len != self.tasks.len / 2)
                    continue;
                for (batch) |i, _| batch[i] = self.tasks[(head + i) % self.tasks.len];
                if (@cmpxchgWeak(u32, &self.head, head, head + batch.len, .Release, .Monotonic) != null)
                    continue;

                // add the batch to the global run_queue
                for (batch) |i, _| batch[i].next = batch[i + 1];
                Task.global.push(batch[0]);
                return;
            }
        }
    }
};

pub const Thread = struct {
    pub const max = 10 * 1000;

    pub var active: usize = undefined;
    pub var idle: os.atomic.Queue(Thread, "next") = undefined;
    pub var cache: os.atomic.Stack(Thread, "next") = undefined;

    pub fn init() {
        active = 0;
        idle.init();
        cache.init();
    }

    next: ?*Thread,
    task: *Task,
    worker: ?*Worker,
    handle: os.thread.Handle,
    event: os.sync.Event,

    pub fn start(worker: *Worker, task: *Task) !void {
        // try and fetch from idle (running) threads if any
        // try and fetch from cache to not allocate if any
        // allocate a new Thread object to use
        const new_thread = thread: {
            if (idle.pop()) |idle_thread| {
                break :thread idle_thread;
            } else if (cache.pop()) |cached_thread| {
                break :thread cached_thread;
            } else {
                const fresh_thread = try worker.heap.allocator.init(Thread);
                fresh_thread.event.init();
                break :thread fresh_thread;
            }
        };

        new_thread.next = null;
        new_thread.task = task;
        new_thread.worker = worker;

        const this_thread =
            if (idle.pop()) |idle_thread| idle_thread
            else if (cache.pop()) |cached_thread| cached_thread
            else value: {
                const new_thread = try worker.heap.allocator.init(Thread);
                new_thread.event.init();
                break :value new_thread;
            };

        this_thread.next = null;
        this_thread.task = task;
        this_thread.worker = worker;

        // signal a running os thread to wakeup or spawn a new os thread
        if (!this_thread.event.is_set()) {
            this_thread.event.signal();
        } else {
            try os.thread.spawn(&this_thread.handle, Thread.run, this_thread);
        }
    }

    fn run(self: *Thread) void {
        // TODO
    }
};

pub const Task = struct {
    pub threadlocal var current: *Task = undefined;

    pub var active: usize = 0;
    pub var global = atomic.Queue(Task, "next").new();

    next: ?*Task,
    status: Status,
    handle: promise,
    thread: *Thread,

    pub const Status = enum {
        Runnable,
        Running,
        Completed,
    };
};




