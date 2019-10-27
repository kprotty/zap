const std = @import("std");
const builtin = @import("builtin");
const zuma = @import("../../zap.zig").zuma;
const zync = @import("../../zap.zig").zync;

const MAX_NUMA_NODES = 64;
const MAX_THREADS_PER_NODE = 16 * 1024;

pub fn run(comptime func: var, args: ...) !@typeOf(func).ReturnType {
    var system: System = undefined;

    // if single_threaded, no need to heap allocate
    if (builtin.single_threaded) {
        var main_node: Node = undefined;
        var main_worker: Worker = undefined;
        try main_node.init(system, null, ([_]*Worker{&main_worker})[0..], 1, null);
        defer main_node.deinit();
        return system.run(([_]*Node{&main_node})[0..]);
    }

    // allocate the node structures & their workers on their defined NUMA nodes
    var node_array: [MAX_NUMA_NODES]*Node = undefined;
    const nodes = node_array[0..zuma.CpuAffinity.getNodeCount()];
    for (nodes) |*node, node_index|
        node.* = try Node.alloc(system, node_index, MAX_THREADS_PER_NODE);
    defer {
        for (nodes) |node|
            node.free();
    }
    return system.run(nodes);
}

const System = struct {
    nodes: []*Node,
    active_tasks: zync.Atomic(usize),

    pub fn run(self: *@This(), nodes: []*Node, comptime func: var, args: ...) !@typeOf(func).ReturnType {
        var main_task: *Task = undefined;
        var result: @typeOf(func).ReturnType = undefined;
        _ = async Task.create(&main_task, saveResult, &result, func, args);
        self.active_tasks.set(1);

        // Use a random NUMA node as the main entry point in order to not over-subscribe
        // nodes if multiple zap applications running on a given system.
        const main_node = nodes[zuma.Thread.getRandom().uintAtMostBiased(usize, nodes.len)];
        self.nodes = nodes;
    }

    fn saveResult(result: *@typeOf(func).ReturnType, comptime func: var, args: ...) void {
        result.* = func(args);
    }
};

pub const Node = struct {
    system: *System,
    numa_node: usize,
    cpu_affinity: zuma.CpuAffinity,
    workers: []*Worker,
    idle_workers: zync.Atomic(usize),
    thread_cache: Thread.Cache,

    pub fn alloc(system: *System, numa_node: usize, max_threads: usize) !*@This() {
        // get the cpu_set for the NUMA node and compute its memory size + offsets
        var cpu_affinity: zuma.CpuAffinity = undefined;
        try cpu_affinity.getCpus(numa_node, .Logical);
        const worker_count = cpu_affinity.count();

        var node_offset: usize = undefined;
        var worker_offset: usize = undefined;
        var worker_array_offset: usize = undefined;
        const size = computeSize(worker_count, &node_offset, &worker_array_offset, &worker_offset);

        // allocate all the memory on the numa node and setup the worker array
        const flags = zuma.PAGE_READ | zuma.PAGE_WRITE | zuma.PAGE_COMMIT;
        const memory = try zuma.map(null, size, flags, numa_node);
        const workers_ptr = @ptrCast([*]Worker, @alignCast(@alignOf([*]Worker), &memory[worker_offset]));
        const workers_array_ptr = @ptrCast([*]*Worker, @alignCast(@alignOf([*]*Worker, &memory[worker_array_offset])));
        const workers = workers_array_ptr[0..worker_count];
        for (workers) |*worker_ref, index|
            worker_ref.* = &workers_ptr[index];

        // finish initialization
        const self = @ptrCast(*@This(), @alignCast(@alignOf(*@This()), &memory[node_offset]));
        try self.init(system, numa_node, workers, max_threads, cpu_affinity);
        return self;
    }

    pub fn free(self: *@This()) void {
        const size = computeSize(self.workers.len);
        const memory = @ptrCast([*]u8, self)[0..size];
        zuma.unmap(memory, self.numa_node);
    }

    pub fn init(
        self: *@This(),
        system: *System,
        numa_node: ?usize,
        workers: []*Worker,
        max_threads: usize,
        affinity: ?zuma.CpuAffinity,
    ) !void {
        self.system = system;
        self.numa_node = numa_node orelse 0;
        self.cpu_affinity = affinity orelse cpu_affinity: {
            var system_affinity: CpuAffinity = undefined;
            system_affinity.clear();
            try system_affinity.getCpus(null, .Logical);
            break :cpu_affinity system_affinity;
        };

        self.workers = workers;
        self.thread_cache.init(max_threads);
        if (self.workers.len == 64) {
            self.idle_workers.set(~usize(0));
        } else {
            const shift = @intCast(zync.ShrType(usize), self.workers.len);
            self.idle_workers.set((usize(1) << shift) - 1);
        }
    }

    pub fn deinit(self: *@This()) void {
        self.thread_cache.deinit();
    }

    fn computeSize(worker_count: usize, offsets: ...) usize {
        // Node offset
        var size: usize = 0;
        if (offsets.len > 0)
            offsets[0].* = size;
        size += @sizeOf(@This());

        // Worker slice offset
        size = std.mem.alignForward(size, @alignOf([*]*Worker));
        if (offsets.len > 1)
            offsets[1].* = size;
        size += @sizeOf(*Worker) * worker_count;

        // Worker array offset
        size = std.mem.alignForward(size, @alignOf(Worker));
        if (offsets.len > 2)
            offsets[2].* = size;
        size += @sizeOf(Worker) * worker_count;
        return size;
    }
};

pub const Worker = struct {
    node: *Node,
    thread: *Thread,

    pub fn isSequential(self: @This()) bool {
        return builtin.single_threaded or self.node.workers.len == 1;
    }
};

pub const Thread = struct {
    pub threadlocal var current: ?*@This() = null;

    next: zync.Atomic(?*@This()),
    worker: *Worker,
    event: zync.Event,
    stack: ?[]align(zuma.page_size) u8,

    pub const Cache = struct {
        mutex: zync.Mutex,
        max_threads: usize,
        active_threads: usize,

        pub fn init(self: *@This(), max_threads: usize) void {
            self.mutex.init();
            self.active_threads = 0;
            self.max_threads = max_threads;
        }

        pub fn deinit(self: *@This()) void {
            self.mutex.deinit();
        }
    };
};

pub const Task = struct {
    next: ?*@This() = null,
    frame: anyframe = undefined,

    pub fn create(ptr: **@This(), comptime func: var, args: ...) @typeOf(func).ReturnType {
        var self = @This(){};
        ptr.* = &self;
        suspend {
            self.frame = @frame();
        }
        return func(args);
    }

    pub const List = struct {
        head: ?*Task = null,
        tail: ?*Task = null,
        size: usize = 0,

        pub fn push(self: *@This(), task: *Task) void {
            if (self.head == null)
                self.head = task;
            if (self.tail) |tail|
                tail.next = task;
            tail = task;
            self.size += 1;
        }
    };
};
