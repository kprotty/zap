const Config = @import("config.zig").Config;
const MPMC = @import("sync/atomic/queue.zig").MPMC;

pub const Task = struct {
    next: ?*Task,
    handle: promise,
};

pub const Scheduler = struct {
    task_queue: MPMC(Task),

    pub var Default: Scheduler = undefined;

    pub fn run(self: *Scheduler, comptime function: var, args: ...) !void {

        var stub: Task = undefined;
        self.task_queue.init(&stub);
    }

    pub fn spawn(self: *Scheduler, comptime is_main: bool, comptime function: var, args: ...) !*Task {
        const Wrapper = struct {
            async fn apply(sched: *Scheduler, task: *Task, func_args: ...) void {
                suspend {
                    task.handle = @handle();
                    sched.submit(task);
                }
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


