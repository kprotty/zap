const std = @import("std");
const system = @import("./system.zig");

pub const Scheduler = struct {
    pub const Config = struct {
        cluster: Node.Cluster = Node.Cluster{},
        main_node: *Node = undefined,
    };

    pub fn runAsync(config: Config, comptime func: var, args: var) !@TypeOf(func).ReturnType {
        const ReturnType = @TypeOf(func).ReturnType;
        const Wrapper = struct {
            fn entry(func_args: var, task: *Task, result: *?ReturnType) void {
                suspend task.* = Task.init(@frame());
                const res = @call(.{}, func, func_args);
                result.* = res;
            }
        };

        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.entry(args, &task, &result);
        try run(config, &task.runnable);
        return result orelse error.DeadLocked;
    }

    pub fn run(config: Config, runnable: *Runnable) !void {
        if (config.cluster.len != 0)
            return runNuma(config.cluster, config.main_node, runnable);

        var main_node: *Node = undefined;
        const numa_nodes = system.Node.getTopology();
        const main_index = system.nanotime() % nodes.len;

        var cluster = Node.Cluster{};
        defer for (cluster.iter()) |node| {
            const begin_ptr = @ptrToInt(node);
            const end_ptr = @ptrToInt(node.workers.ptr + node.workers.len);
            const memory = @intToPtr([*]align(std.mem.page_size) u8, begin_ptr)[0..(end_ptr - begin_ptr)];
            node.numa_node.unmap(memory);
        }

        for (numa_nodes) |*numa_node, index| {
            const num_workers = numa_node.affinity.count();
            const worker_offset = std.mem.alignForward(@sizeOf(Node), @alignOf(Worker));
            const memory = try numa_node.map(worker_offset + (@sizeOf(Worker) * num_workers));

            const node = @ptrCast(*Node, @alignCast(@alignOf(Node), memory.ptr));
            const workers = @ptrCast([*]Worker, @alignCast(@alignOf(Worker), &memory[worker_offset]))[0..num_workers];
            node.init(workers);

            cluster.push(node);
            if (index == main_index)
                main_node = node;
        }

        return runNuma(cluster, main_node, runnable);
    }

    fn runNuma(cluster: Node.Cluster, main_node: *Node, runnable: *Runnable) !void {
        var active_nodes: usize = 0;
        defer std.debug.assert(@atomicLoad(usize, &active_nodes, .SeqCst) == 0);

        var nodes = cluster.iter();
        while (nodes.next()) |node|
            node.active_nodes_ptr = &active_nodes;

        main_node.push(Runnable.Batch.from(runnable));
        _ = main_node.tryResumeThread();

        var nodes = cluster.iter();
        while (nodes.next()) |node|
            node.deinit();
    }
};

const CACHE_LINE = switch (std.builtin.arch) {
    .x86_64 => 64 * 2,
    else => 64,
};

pub const Node = extern struct {
    pub const Cluster = struct {
        head: ?*Node = null,
        tail: ?*Node = null,
        len: usize = 0,

        pub fn iter(self: Cluster) Iter {
            return Iter.init(self.head);
        }

        pub fn push(self: *Cluster, node: *Node) void {
            if (self.head == null)
                self.head = node;
            if (self.tail) |tail|
                tail.next = node;
            node.next = node;
            self.len += 1;
        }

        pub fn pop(self: *Cluster) ?*Node {
            const node = self.head orelse return null;
            self.head = node.next;
            if (self.head == node) {
                self.head = null;
                self.tail = null;
            }
            node.next = node;
            self.len -= 1;
            return node;
        }
    };

    pub const Iter = struct {
        start: *Node,
        node: ?*Node,

        pub fn init(node: ?*Node) Iter {
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

    const AtomicUsize = switch (std.builtin.arch) {
        .i386, .x86_64 => extern struct {
            value: usize align(@alignOf(DoubleWord)),
            aba_tag: usize = 0,

            const DoubleWord = @Type(std.builtin.TypeInfo{
                .Int = std.builtin.TypeInfo.Int{
                    .is_signed = false,
                    .bits = @typeInfo(usize).Int.bits * 2,
                },
            });

            fn load(
                self: *const AtomicUsize,
                comptime ordering: std.builtin.AtomicOrder,
            ) AtomicUsize {
                return AtomicUsize{
                    .value = @atomicLoad(usize, &self.value, ordering),
                    .aba_tag = @atomicLoad(usize, &self.aba_tag, .SeqCst),
                };
            }

            fn cmpxchgWeak(
                self: *AtomicUsize,
                compare: AtomicUsize,
                exchange: usize,
                comptime success: std.builtin.AtomicOrder,
                comptime failure: std.builtin.AtomicOrder,
            ) ?AtomicUsize {
                const double_word = @cmpxchgWeak(
                    DoubleWord,
                    @ptrCast(*DoubleWord, self),
                    @bitCast(DoubleWord, compare),
                    @bitCast(DoubleWord, AtomicUsize{
                        .value = exchange,
                        .aba_tag = compare.aba_tag +% 1,
                    }),
                    success,
                    failure,
                ) orelse return null;
                return @bitCast(AtomicUsize, double_word);
            }
        },
        else => extern struct {
            value: usize,

            fn load(
                self: *const AtomicUsize,
                comptime ordering: std.builtin.AtomicOrder,
            ) AtomicUsize {
                const value = @atomicLoad(usize, &self.value, ordering);
                return AtomicUsize{ .value = value };
            }

            fn cmpxchgWeak(
                self: *AtomicUsize,
                compare: AtomicUsize,
                exchange: usize,
                comptime success: std.builtin.AtomicOrder,
                comptime failure: std.builtin.AtomicOrder,
            ) ?AtomicUsize {
                const value = @cmpxchgWeak(
                    usize,
                    &self.value,
                    compare.value,
                    exchange,
                    success,
                    failure,
                ) orelse return null;
                return AtomicUsize{ .value = value };
            }
        },
    };

    active_workers: usize align(CACHE_LINE),
    idle_workers: AtomicUsize align(CACHE_LINE),
    runq_head: *Runnable align(CACHE_LINE),
    runq_locked: bool,
    runq_tail: *Runnable,
    runq_stub: ?*Runable,
    next: *Node align(CACHE_LINE),
    workers_ptr: [*]Worker,
    workers_len: usize,
    numa_node: *system.Node,
    stack_size: usize,
    active_nodes_ptr: *usize,

    pub fn init(
        self: *Node,
        workers: []Worker,
        numa_node: *system.Node,
        thread_stack_size: usize,
    ) void {
        const runq_stub = @fieldParentPtr(Runnable, "next", &self.runq_stub);
        self.* = Node{
            .active_workers = 0,
            .idle_workers = AtomicUsize{ .value = 0 | WORKER_TAG_WORKER },
            .runq_head = runq_stub,
            .runq_locked = false,
            .runq_tail = runq_stub,
            .runq_stub = null,
            .next = self,
            .workers_ptr = workers.ptr,
            .workers_len = workers.len,
            .numa_node = numa_node,
            .stack_size = std.mem.alignForward(std.math.max(8 * 1024, thread_stack_size), std.mem.page_size),
            .active_nodes_ptr = undefined,
        };

        for (workers) |*worker| {
            worker.* = Worker.encode(self.idle_workers.value, .worker);
            self.idle_workers = AtomicUsize{ .value = @ptrToInt(worker) };
        }
    }

    fn deinit(self: *Node) void {
        defer self.* = undefined;

        std.debug.assert(self.idle_workers.load(.SeqCst).value == IDLE_STOPPED);
        std.debug.assert(@atomicLoad(usize, &self.active_workers, .SeqCst) == 0);

        const runq_stub = @fieldParentPtr(Runnable, "next", &self.runq_stub);
        std.debug.assert(@atomicLoad(*Runnable, &self.runq_head, .SeqCst) == runq_stub);
        std.debug.assert(!@atomicLoad(bool, &self.runq_locked, .SeqCst));
        std.debug.assert(self.runq_tail == runq_stub);

        for (self.workers) |*worker_ptr| {
            
        }
    }

    pub fn iter(self: *Node) Iter {
        return Iter.init(self);
    }

    fn resumeThread(self: *Node) void {
        var nodes = self.iter();
        while (nodes.next()) |node| {
            if (node.tryResumeThread())
                break;
        }
    }

    fn tryResumeThread(self: *Node) bool {
        
    }

    fn suspendThread(
        noalias self: *Node,
        noalias thread: *Thread,
        noalias worker: *Worker,
    ) void {
        
    }
};

pub const Worker = extern struct {
    ptr: usize align(8),

    const Tag = enum(u2) {
        node,
        thread,
        handle,
        worker,
    };

    fn encode(ptr: usize, tag: Tag) Worker {
        return Worker{ .ptr = ptr | @enumToInt(tag) };
    }

    fn decodePtr(self: Worker) usize {
        return self.ptr & ~@as(usize, ~@as(@TagType(Tag), 0));
    }

    fn decodeTag(self: Worker) Tag {
        return @intToEnum(Tag, @truncate(@TagType(Tag), self.ptr));
    }
};

pub const Thread = struct {
    pub threadlocal var current: ?*Thread = null;

    const State = enum {
        running,
        waking,
        stopped,
    };

    next: usize,
    state: State,
    event: system.Event,
    handle: ?*system.Thread,

    fn run(handle: ?*system.Thread, worker: *Worker) void {

    }
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
        len: usize = 0,

        pub fn from(runnable: *Runnable) Batch {
            var self = Batch{};
            self.push(runnable);
            return self;
        }

        pub fn pushBatch(self: *Batch, other: Batch) void {
            if (other.len == 0)
                return;
            if (self.head == null)
                self.head = other.head;
            if (self.tail) |tail|
                tail.next = other.head;
            self.tail = other.tail;
            self.len += other.len;
        }

        pub fn push(self: *Batch, runnable: *Runnable) void {
            if (self.head == null)
                self.head = runnable;
            if (self.tail) |tail|
                tail.next = runnable;
            self.tail = runnable;
            runnable.next = null;
            self.len += 1;
        }

        pub fn pop(self: *Batch) ?*Runnable {
            const runnable = self.head orelse return null;
            self.head = runnable.next;
            if (self.head == null)
                self.tail = null;
            self.len -= 1;
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

    fn @"resume"(runnable: *Runnable) callconv(.C) void {
        const task = @fieldParentPtr(Task, "runnable", runnable);
        resume task.frame;
    }

    pub fn schedule(self: *Task) void {
        return Runnable.Batch.from(&self.runnable).schedule();
    }

    pub fn yield() void {
        var task = Task.init(@frame());
        suspend task.schedule();
    }
};
