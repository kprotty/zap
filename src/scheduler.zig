const std = @import("std");
const builtin = @import("builtin");

/// sysmon ()
pub const Scheduler = struct {
    pub var current: Scheduler = undefined;
    
    active_tasks: usize,
    allocator: *std.mem.Allocator,

    workers: []Worker,
    idle_workers: SharedQueue(Worker, "link"),

    pub const Config = struct {
        max_workers: usize,
        allocator: *std.mem.Allocator,

        pub fn default() Config {
            return Config {
                .allocator = std.debug.allocator,
                .max_workers = std.Thread.cpuCount() catch 1,
            };
        }
    };

    pub fn run(config: Config, comptime function: var, args: ...) !void {
        // initialize the scheduler
        var self: Scheduler = undefined;
        self.allocator = config.allocator;

        // create the main task to run
        const main_task = try self.spawn_task(function, args);
        errdefer self.allocator.deinit(main_task);
        self.active_tasks = 1;

        // allocate workers, initialize them and add them to the idle_workers queue
        self.workers = try self.allocator.alloc(Worker, std.math.max(config.max_workers, 1));
        defer self.allocator.free(self.workers);
        self.idle_workers.init();
        for (self.workers[1..]) |*worker| {
            worker.init();
            self.idle_workers.push(worker);
        }

        // create the main thread and run the first worker using it
        var thread: Thread = undefined;
        self.workers[0].init();
        thread.run(&self.workers[0], main_task);

        // wait for all threads to complete
        for (self.workers[1..]) |worker| {
            if (worker.thread.inner) |std_thread| {
                std_thread.wait();
            }
        }
    }

    pub fn spawn(self: *Scheduler, comptime function: var, args: ...) !void {
        // TODO
    }

    fn spawn_task(self: *Scheduler, comptime function: var, args: ...) !*Task {
        const TaskWrapper = struct {
            async fn func(sched: *Scheduler, task: *Task, fargs: ...) void {
                suspend {
                    task.handle = @handle();
                    task.state = .Runnable;
                }
                _ = await (async function(fargs) catch unreachable);
                task.state = .Completed;
            }
        };
        const task = try self.allocator.init(Task);
        try async<self.allocator> TaskWrapper.func(self, task, args);
        return task;
    }
};

pub const Task = struct {
    data: usize,
    link: ?*Task,
    state: State,
    handle: promise,
    
    pub const State = enum {
        Runnable,
        Completed,
    };
};

pub const Thread = struct {
    pub threadlocal var current: Thread = undefined;

    task: *Task,
    worker: *Worker,
    inner: ?*std.Thread,

    pub fn submit(self: *Thread, task: *Task) void {
        const scheduler = Scheduler.current;
        _ = @atomicRmw(usize, &scheduler.active_tasks, .Add, 1, .SeqCst);

        // try and add to run queue
        // if it wasnt empty, try getting a free P
        // if got free P, fetch/create new M to run P
    }

    pub fn run(self: *Thread, worker: *Worker, task: *Task, inner: ?*std.Thread) !void {
        // if sysmon tick, iterate workers and steal syscalled Workers
        self.task = task;
        self.inner = inner;
        self.worker = worker;
        worker.thread = self;

        // keep operating while theres still live tasks
        const scheduler = Scheduler.current;
        while (@atomicLoad(usize, &scheduler.active_tasks, .SeqCst) > 0) {
            resume task.handle;
            
            // when task completed, decrement active_tasks and stop running 
            if (task.state == .Completed) {
                scheduler.allocator.deinit(task);
                if (@atomicRmw(usize, &scheduler.active_tasks, .Sub, 1, .SeqCst) == 1)
                    return;
            }
        }
    }
};

pub const Worker = struct {
    link: ?*Worker,

    task: *Task,
    thread: *Thread,

    pub fn init(self: *Worker) void {
        
    }
};

fn SharedQueue(comptime Node: type, comptime Field: []const u8) type {
    const Queue = struct {
        head: *Node,
        tail: *Node,
        stub: ?*Node,

        pub fn init(self: *Queue) void {
            self.head = @fieldParentPtr(Node, Field, &self.stub);
            self.tail = self.head;
            self.stub = null;
        }

        pub fn push(self: *Queue, node: *Node) void {
            @fence(.Release);
            const prev = @atomicRmw(*Node, &self.head, .Xchg, node, .Monotonic);
            @field(prev, Field) = node; // TODO: replace with atomicStore() https://github.com/ziglang/zig/issues/2995
        }

        pub fn pop(self: *Queue) ?*Node {
            var tail = @atomicLoad(*Node, &self.tail, .Unordered);
            while (true) {
                const next = @atomicLoad(?*Node, &@field(tail, Field), .Unordered) orelse return null;
                if (@cmpxchgWeak(*Node, &self.tail, tail, next, .Monotonic, .Monotonic)) |new_tail| {
                    tail = new_tail;
                    continue;
                }
                @fence(.Acquire);
                return next;
            }
        }

        fn isValidNode() bool {
            const field = if (@hasField(Node, Field)) @typeOf(@field(Node(undefined), Field)) else return false;
            const ftype = if (@typeId(field) == .Optional) @typeInfo(field).Optional.child else return false;
            const ptype = if (@typeId(ftype) == .Pointer) @typeInfo(ftype).Pointer else return false;
            return ptype.size == .One and ptype.child == Node;
        }
    };

    comptime std.debug.assert(Queue.isValidNode());
    return Queue;
}