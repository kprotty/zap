const std = @import("std");
const builtin = @import("builtin");

const os = switch (builtin.os) {
    .linux = @import("os/os_linux.zig"),
    .windows = @import("os/os_windows.zig"),
    else => @import("os/os_posix.zig"),
};

pub const Loop = struct {
    pub var current: ?*Loop = null;
    
    /// loop variables
    max_threads: usize,
    max_concurrency: usize,
    allocator: *std.mem.Allocator,

    /// worker variables
    main_worker: Worker,
    extra_workers: ?[]Worker,
    run_queue: GlobalRunQueue,

    /// thread variables
    main_thread: Thread,
    stack_size: usize,
    active_threads: usize,
    idle_threads: AtomicStack(Thread),

    pub const Config = struct {
        max_threads: ?usize,
        max_concurrency: ?usize,
        allocator: ?*std.mem.Allocator,

        pub fn default() Config {
            return Config {
                .allocator = null,
                .max_threads = null,
                .max_concurrency = null,
            };
        }
    };

    pub fn init(self: *@This(), config: Config) !void {
        // init loop variables
        current = self;
        self.allocator = config.allocator orelse std.heap.direct_allocator;
        self.max_threads = if (builtin.single_threaded) 1 else std.math.max(1, config.max_threads orelse (1 << 16));
        self.max_concurrency = std.math.min(self.max_threads, std.math.max(1, config.max_concurrency orelse os.Thread.cpuCount()));

        // init worker variables
        std.debug.assert(self.max_concurrency > 0);
        self.extra_workers = if (self.max_concurrency > 1) try self.allocator.alloc(Worker, self.max_concurrency) else null;
        if (self.extra_workers) |workers| for (workers) |*worker| worker.init();
        self.main_worker.init();
        self.run_queue.init();

        // init thread variables
        self.active_threads = 0;
        self.idle_threads.init();
        Thread.current = &self.main_thread;
        self.main_thread.init(&self.main_worker);
        self.stack_size = os.Thread.stackSize(Thread.run);
    }

    pub fn run(self: *@This()) void {
        self.main_thread.run();

        if (self.extra_workers) |workers| self.allocator.free(workers);
        Thread.current = null;
    }

    pub fn call(self: *@This(), comptime function: var, args: ...) @typeOf(function).ReturnType {
        yield();
        return function(args);
    }

    pub fn yield(self: *@This()) void {
        suspend {
            var task = Task {
                .link = null,
                .frame = @frame(),
            };
            if (Thread.current) |thread|
                thread.worker.run_queue.put(&task);
        }
    }

    const Task = struct {
        link: ?*Task,
        frame: anyframe,
    };

    const Thread = struct {
        pub threadlocal var current: ?*Thread = null;

        link: ?*Thread,
        worker: *Worker,
        
        pub fn run(self: *@This()) void {
            _ = @atomicRmw(usize, &self.active_threads, .Add, 1, .Acquire);
            while (self.worker.findTask()) |task|
                resume task.frame;
            _ = @atomicRmw(usize, &self.active_threads, .Sub, 1, .Release);
        }
    };

    const Worker = struct {
        thread: ?*Thread,
        run_queue: LocalRunQueue,

        pub fn init(self: *@This()) void {
            self.thread = null;
            self.run_queue.init();
        }

        pub fn findTask(self* @This()) ?*Task {
            if (self.run_queue.get()) |task|
                return task;
            if ()
        }
    };

    const LocalRunQueue = struct {
        head: u32,
        tail: u32,
        tasks: [256]*Task,

        pub fn init(self: *@This()) void {

        }

        pub fn put(self: *@This(), task: *Task) void {

        }

        pub fn get(self: *@This()) ?*Task {
            return null;
        }
    };

    const GlobalRunQueue = struct {
        lock: usize,
        head: ?*Task,
        tail: ?*Task,
        
        pub fn init(self: *@This()) void {
            self.lock = 0;
            self.head = null;
            self.tail = null;
        }
    };

    fn AtomicStack(comptime Node: type) type {
        return struct {

        };
    }
};