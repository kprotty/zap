const MPMC = @import("sync/atomic/queue.zig").MPMC;

pub const Task = struct {
    next: ?*Task,
    handle: promise,
};

pub const Scheduler = struct {
    workers: []Worker,
    task_queue: MPMC(Task),
    allocator: *std.mem.Allocator,

    var main_task: *Task = undefined;
    pub var Current: Scheduler = undefined;

    pub fn run(self: *Scheduler, allocator: *std.mem.Allocator, num_workers: usize, comptime function: var, args: ...) !void {
        var stub: Task = undefined;
        self.task_queue.init(&stub);
        main_task = try spawn(function, args);
        self.task_queue.push(main_task);

        var num_threads = 
            if (builtin.single_threaded) 1
            else if (num_workers == 0) try std.Thread.cpuCount()
            else num_workers;

        self.workers = try allocator.alloc(Worker, num_threads);
        while (num_threads > 1) : (num_threads -= 1)
            self.workers[num_threads].thread_id = try std.Thread.spawn(num_threads, worker);
        self.workers[0].thread_id = std.Thread.getCurrentId();
        
    }

    pub fn spawn(self: *Scheduler, comptime function: var, args: ...) !*Task {
        const Wrapper = struct {
            async fn apply(sched: *Scheduler, task: *Task, func_args: ...) void {
                suspend { task.handle = @handle(); }
                _ = await (async function(func_args) catch unreachable);
            }
        };
        var task = try Config.Default.allocator.init(Task);
        _ = try async<Config.Default.allocator> Wrapper.apply(self, task, args);
        return task;
    }

    pub fn blocking(self: *Scheduler, comptime function: var, args: ...) !@typeOf(function).ReturnType {
        return function(args); // TODO
    }

    pub async fn yield(self: *Scheduler) void {
        // TODO
    }
};


