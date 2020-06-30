const std = @import("std");
pub const numa = @import("./numa.zig");

pub const Scheduler = struct {
    pub const Config = union(enum) {
        smp: Smp,
        numa: Numa,

        pub fn default() Config {
            return Config{ .smp = Smp{} };
        }

        pub const Smp = struct {
            max_threads: usize = 0,
        };

        pub const Numa = struct {
            cluster: Node.Cluster,
            start_node: *Node,
        };
    };

    pub fn runAsync(config: Config, comptime func: var, args: var) !@TypeOf(func).ReturnType {
        const ReturnType = @TypeOf(func).ReturnType;
        const Wrapper = struct {
            fn entry(func_args: var, task: *Task, result: *?ReturnType) void {
                suspend task.* = Task.init(@frame());
                const ret_val = @call(.{}, func, func_args);
                result.* = ret_val;
            }
        };

        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.entry(args, &task, &result);
        try run(config, &task.runnable);
        return result orelse error.DeadLocked;
    }

    pub fn run(config: Config, runnable: *Runnable) !void {
        return switch (config) {
            .numa => |cluster| runOnCluster(cluster, runnable),
            .smp => |smp_cfg| blk: {
                var max_threads = smp_cfg;
                var cluster = 
                const topology = numa.Node.getTopology();
                
            },
        };
    }

    fn runOnCluster(cluster: Node.Cluster, runnable: *Runnable) !void {

    }
};

pub const Node = struct {
    pub const Iter = struct {
        start: *Node,
        node: ?*Node,

        pub fn init(node: ?*Node) {
            return Iter{
                .start = node orelse undefined,
                .node = node,
            };
        }

        pub fn next(self: *Iter) ?*Node {
            const node = self.node orelse return null;
            self.node = node.next;
            if (self.node == self.start)
                self.node = null;
            return node;
        }
    };

    pub const Cluster = struct {
        head: ?*Node = null,
        tail: ?*Node = null,

        pub fn iter(self: Cluster) Iter {
            return Iter.init(self.head);
        }

        pub fn push(self: *Cluster, node: *Node) void {
            if (self.head == null)
                self.head = node;
            if (self.tail) |tail|
                tail.next = node;
            self.tail = node;
            node.next = node;
        }

        pub fn pop(self: *Cluster) ?*Node {
            const node = self.head orelse return null;
            self.head = node.next;
            if (self.head == null)
                self.tail = null;
            node.next = node;
            return node;
        }
    };

    pub const Worker = struct {
        thread: ?*Thread = null,
        handle: ?*std.Thread = null,
    };

    next: *Node,
    numa_node: *numa.Node,
    lock: std.Mutex,
    runq: Runnable.Batch,
    runq_size: usize,
    max_threads: usize,
    free_threads: usize,
    active_threads: usize,
    idle_threads: ?*Thread,
    workers: []Worker,
    searching_workers: usize,

    pub fn init(
        self: *Node,
        numa_node: *numa.Node,
        workers: []Worker,
        max_threads: usize,
    ) void {
        self.* = Node{
            .next = undefined,
            .numa_node = numa_node,
            .lock = std.Mutex.init(),
            .runq = Runnable.Batch{},
            .runq_size = 0,
            .max_threads = max_threads,
            .free_threads = max_threads,
            .active_threads = 0,
            .idle_threads = null,
            .workers = workers,
            .searching_workers = 0,
        };

        self.next = self;
        for (workers) |*worker|
            worker.* = Worker{};
    }

    pub fn deinit(self: *Node) void {
        defer self.* = undefined;

        self.lock.deinit();
        std.debug.assert(self.runq.isEmpty());
        std.debug.assert(self.runq_size == 0);
        std.debug.assert(self.active_threads == 0);
        std.debug.assert(self.free_threads == self.max_threads);

        std.debug.assert(self.searching_workers == 0);
        for (self.workers) |*worker| {
            std.debug.assert(worker.thread == null);
            std.debug.assert(worker.handle == null);
        }
    }

    pub fn iter(self: *Node) Iter {
        return Iter.init(self);
    }
};

const Thread = struct {
    next: ?*Thread,
};

pub const Runnable = struct {
    next: ?*Runnable = undefined,
    callback: Callback,

    pub fn init(callback: Callback) Runnable {
        return Runnable{ .callback = callback };
    }

    pub const Callback = fn(*Runnable) callconv(.C) void;

    pub const Batch = struct {
        head: ?*Runnable = null,
        tail: ?*Runnable = null,

        pub fn from(runnable: *Runnable) Batch {
            var self = Batch{};
            self.push(runnable);
            return self;
        }

        pub fn push(self: *Batch, runnable: *Runnable) void {
            if (self.head == null)
                self.head = runnable;
            if (self.tail) |tail|
                tail.next = runnable;
            self.tail = runnable;
            runnable.next = null;
        }

        pub fn pop(self: *Batch) ?*Runnable {
            const runnable = self.head orelse return null;
            self.head = runnable.next;
            if (self.head == null)
                self.tail = null;
            return runnable;
        }

        pub fn schedule(self: Batch) void {
            if (Thread.current) |thread| {
                thread.schedule(self);
            } else {
                std.debug.panic("Runnable.Batch.schedule() outside Scheduler", .{});
            }
        }
    };
};

pub const Task = struct {
    runnable: Runnable = Runnable.init(@"resume"),
    frame: anyframe,

    pub fn init(frame: anyframe) Task {
        return Task{ .frame = frame };
    }

    pub fn schedule(self: *Task) void {
        return Batch.from(&self.runnable).schedule();
    }

    fn @"resume"(runnable: *Runnable) callconv(.C) void {
        const task = @fieldParentPtr(Task, "runnable", runnable);
        resume task.frame;
    }
};