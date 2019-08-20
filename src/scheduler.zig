const std = @import("std");
const builtin = @import("builtin");

const os = struct {
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

pub var system: System = undefined;
pub const System = struct {
    allocator: *std.mem.Allocator,
    workers: ?[]Worker,
    main_worker: Worker,
    run_queue: Worker.GlobalTaskQueue,

    max_threads: usize,
    main_thread: Thread,
    live_threads: os.sync.Futex,
    idle_threads: os.sync.AtomicStack(Thread, "link"),

    main_task: Task,
    live_tasks: usize,

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
        var task_memory: [Task.byteSize(function)]u8 align(Task.alignment(function)) = undefined;
        const main_task = try Task.spawn(task_memory[0..], function, args);
        self.main_thread.run(&self.main_worker, main_task);

        // wait for all threads to finish
        while (self.idle_threads.get()) |idle_thread| {
            _ = @atomicRmw(usize, &self.live_threads.value, .Add, 1, .Release);
            idle_thread.futex.wake(false);
        }
        while (@atomicLoad(usize, &self.live_threads.value, .Acquire) > 0)
            self.live_threads.wait(self.live_threads.value, null);
    }
};

pub const Task = struct {
    link: ?*Task,
    frame: anyframe,
    heap_allocated: bool,

    pub fn alignment(comptime function: var) usize {
        return @alignOf(@Frame(Spawn(function).func));
    }

    pub fn byteSize(comptime function: var) usize {
        return std.mem.alignForward(@sizeOf(@This()), alignment(function)) + @frameSize(Spawn(function).func);
    }

    pub fn spawn(memory: ?[]align(alignment(function)) u8, comptime function: var, args: ...) !*Task {
        var heap_allocated = false;
        var task_memory: []align(alignment(function)) u8 = undefined;
        if (memory) |user_memory| {
            task_memory = user_memory;
        } else {
            task_memory = try system.allocator.alignedAlloc(u8, alignment(function), byteSize(function));
            heap_allocated = true;
        }

        const frame_memory = task_memory[0..std.mem.alignForward(@sizeOf(@This()), alignment(function))];
        const task = @ptrCast(*Task, @alignCast(@alignOf(*Task), task_memory.ptr));
        if (task_memory.len < byteSize(function))
            return std.mem.Allocator.Error.OutOfMemory;

        task.frame = @asyncCall(frame_memory, {}, Spawn(function).func, task, args);
        task.heap_allocated = heap_allocated;
        task.link = null;
        return task;
    }

    fn Spawn(comptime function: var) type {
        return struct {
            fn func(task: *Task, args: ...) void {
                suspend;
                _ = await function(args);
                suspend {
                    if (task.heap_allocated)
                        system.allocator.free(@ptrCast([*]u8, task)[0..byteSize(function)]);
                }
            }
        };
    }
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
        _ = @atomicRmw(usize, &self.live_threads.value, .Add, 1, .Release);
    }

    pub fn run(self: *@This(), worker: *Worker, task: *Task) void {
        self.init(worker);
        self.worker.run_queue.put(task);
        
        // TODO: run worker's tasks

        if (@atomicRmw(usize, &system.live_threads.value, .Sub, 1, .Release) == 1)
            system.live_threads.wake(false);
    }
};

pub const Worker = struct {
    thread: ?*Thread,
    run_queue: LocalTaskQueue,

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
};