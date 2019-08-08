const std = @import("std");
const builtin = @import("builtin");

const atomic = @import("atomic.zig");
const heap = @import("heap.zig").Heap;

pub const Config = struct {
    max_workers: usize,

    pub fn default() Config {
        return Config {
            .max_workers = std.Thread.cpuCount() catch 1,
        };
    }
};  

pub const System = struct {
    heap: Heap,

    pub fn run(self: *System, config: Config, comptime function: var, args: ...) !void {
        self.heap.init();
        defer self.heap.deinit();

        Thread.init();
        Task.global.init();
        try Worker.init();
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
    pub var idle: atomic.Queue(Worker, "next") = undefined;

    pub fn init(heap: *Heap, max_workers: usize) !void {
        idle.init();
        all = try self.heap.allocator.alloc(std.math.max(1, config.max_workers));
        for (all) |*worker| {
            worker.heap.init();
            worker.status = .Idle;
            idle.push(worker);
        }
    }

    pub fn deinit(heap: *Heap) void {
        for (all) |*worker|
            worker.heap.deinit();
        heap.allocator.free(all);
        all = []Worker {};
    }

    status: Status,
    next: ?*Worker,
    heap: Heap,
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

        // spawn the task and try and create a new Thread using an idle Worker
        // if theres no idle workers, add to the local run queue.
        const task = try self.heap.allocator.init(Task);
        _ = try async<allocator> TaskWrapper.func(task, args);
        if (idle.pop()) |idle_worker| {
            try Thread.spawn(idle_worker, task);
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
                const tail = @atomicLoad(u32, &self.tail, .Monotonic);
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
    pub var num_spinning = usize(0);

    pub var idle: atomic.Queue(Thread, "next") = undefined;
    pub var cache: atomic.Stack(Thread, "next") = undefined;

    next: ?*Thread,
    worker: *Worker,
    handle: ?*std.Thread,

    pub fn run(self: *Thread) void {

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

    pub fn spawn(task: *Task, allocator: *std.mem.Allocator, comptime function: var, args: ...) !void {
        
    }
};




