const std = @import("std");
const builtin = @import("builtin");

const sync = @import("./sync.zig");
usingnamespace @import("./reactor.zig");
const system = switch (builtin.os) {
    .windows => @import("./system/windows.zig"),
    .linux => @import("./system/linux.zig"),
    else => @import("./system/posix.zig"),
};

pub const Executor = struct {
    nodes: []*Node,
    next_node: u32,
    active_workers: u32,
    active_tasks: usize,

    pub fn run(comptime entry: var, args: ...) !void {
        if (builtin.single_threaded)
            return runSequential(entry, args);
        return runParallel(entry, args);
    }

    pub fn runSequential(comptime entry: var, args: ...) !void {
        var workers = [_]Worker{undefined};
        var node = Node.init(workers[0..], null);
        defer node.deinit();
        var nodes = [_]*Node{ &node };
        return runUsing(nodes[0..], entry, args);
    }

    pub fn runParallel(comptime entry: var, args: ...) !void {
        if (builtin.single_threaded)
            @compileError("--single-threaded doesn't support parallel execution");
        
        var node_array = [_]?*Node{null} ** 64;
        const node_count = std.math.min(system.getNodeCount(), node_array.len);
        const nodes = @ptrCast([*]*Node, &node_array[0])[0..node_count];

        defer for (node_array[0..node_count]) |*node_ptr| {
            if (node_ptr.*) |node|
                node.free();
        }
        for (nodes) |*node_ptr, index|
            node_ptr.* = try Node.alloc(index, null, null);
        return runUsing(nodes, entry, args);
    }

    pub fn runSMP(max_workers: usize, max_threads: usize, comptime entry: var, args: ...) !void {
        const node = try Node.alloc(0, max_workers, max_threads);
        defer node.free();
        var nodes = [_]*Node{ node };
        return runUsing(nodes[0..], entry, args);
    }

    pub fn runUsing(nodes: []*Node, comptime entry: var, args: ...) !void {
        var executor = Executor{
            .nodes = nodes,
            .next_node = 0,
            .active_workers = 0,
            .active_tasks = 0,
        };
        for (nodes) |node|
            node.executor = &executor;

        var main_task: Task = undefined;
        _ = async Task.prepare(&main_task, entry, args);
        
        const main_node = nodes[system.getRandom().uintAtMost(usize, nodes.len)];
        const main_worker = &main_node.workers[main_node.idle_workers.get().?];
        main_worker.submit(&main_task);
        main_worker.run();
    }
};

pub const Node = struct {
    executor: *Executor,
    workers: []Worker,
    idle_workers: sync.BitSet,
    thread_pool: Thread.Pool,
    thread_mutex: std.Mutex align(sync.CACHE_LINE),
    
    pub fn init(workers: []Worker, stacks: []align(Thread.STACK_ALIGN) u8) !Node {
        return Node{
            .executor = undefined,
            .workers = workers,
            .idle_workers = sync.BitSet.init(workers.len),
            .thread_pool = Thread.Pool.init(stacks, @intCast(u16, workers.len)),
            .thread_mutex = std.Mutex.init(),
        };
    }

    pub fn deinit(self: *Node) void {
        self.thread_pool.deinit();
        self.* = undefined;
    }

    pub fn alloc(numa_node: u32, max_workers: ?usize, max_threads: ?usize) !*Node {
        
    }

    pub fn free(self: *Node) void {
        self.deinit();
    }
};

const Thread = struct {
    threadlocal var current: ?*Thread = null;

    const STACK_ALIGN = std.mem.page_size;
    const STACK_SIZE = 16 * 1024; // PTHREAD_STACK_MIN
    const MAX_STACKS = @as(comptime_int, ~@as(u16, 0));

    node: *Node,
    stack: usize,
    next: ?*Thread,
    worker: ?*Worker,
    handle: system.ThreadHandle,

    const EXIT_WORKER = @intToPtr(*Worker, 0x1);
    const MONITOR_WORKER = @intToPtr(*Worker, 0x2);

    fn wakeWith(self: *Thread, worker: *Worker) void {
        // TODO
    }

    fn entry(spawn_info: *SpawnInfo) void {
        var self = spawn_info.initThread();
        spawn_info.setThread(&self);
        // TODO
    }

    const SpawnInfo = struct {
        node: *Node,
        stack: usize,
        thread: ?*Thread,
        worker: ?*Worker,
        handle: system.ThreadHandle,

        fn init(worker: ?*Worker) SpawnInfo {
            return SpawnInfo{
                .node = undefined,
                .stack = 0,
                .thread = null,
                .worker = worker,
                .handle = undefined,
            };
        }

        fn initThread(self: SpawnInfo) Thread {
            return Thread{
                .node = self.node,
                .stack = self.stack,
                .next = null,
                .worker = self.worker,
                .handle = self.handle,
            };
        }

        fn deinit(self: *SpawnInfo) void {
            self.* = undefined;
            // TODO: Maybe use std.ThreadParker instead of sched_yield loop?
        }

        fn setThread(self: *SpawnInfo, thread: *Thread) void {
            @atomicStore(?*Thread, &self.thread, thread, .Release);
        }

        fn getThread(self: *const SpawnInfo) *Thread {
            while (true) : (std.os.sched_yield() catch {}) {
                return @atomicLoad(?*Thread, &self.thread, .Acquire) orelse continue;
            }
        }
    };

    const Pool = struct {
        stack_ptr: usize,
        stack_top: u16,
        num_stacks: u16,
        max_active: u16,
        active_threads: u16,
        free_stack: ?*?*usize,
        free_thread: ?*Thread,

        pub const Error = error{
            InvalidThreadStack,
        };

        fn init(stacks: []align(Thread.STACK_ALIGN) u8, max_active: u16) Error!Pool {
            if (stacks.len % Thread.STACK_SIZE != 0)
                return Error.InvalidThreadStack;
            const num_stacks = @truncate(u16, std.math.min(MAX_STACKS, stacks.len / Thread.STACK_SIZE));
            return Pool{
                .stack_ptr = @ptrToInt(stacks.ptr),
                .stack_top = num_stacks,
                .num_stacks = num_stacks,
                .max_active = max_active,
                .active_threads = 0,
                .free_stack = null,
                .free_thread = null,
            };
        }

        fn deinit(self: *Pool) void {
            const mutex = &@fieldParentPtr(Node, "thread_pool", self).thread_mutex;
            const held = mutex.acquire();
            defer held.release();
            defer mutex.deinit();
            self.* = undefined;

            while (self.free_thread) |t| {
                t.wakeWith(Thread.EXIT_WORKER);
                system.joinThread(t.handle);
            }
        }

        fn put(self: *Pool, thread: *Thread) void {
            const node = @fieldParentPtr(Node, "thread_pool", self);
            const held = node.thread_mutex.acquire();
            
            // destroy the thread if theres too many active ones
            if (self.active_threads >= self.max_active) {
                if (thread.stack != 0) {
                    const ptr = @intToPtr(?*?*usize, thread.stack + Thread.STACK_SIZE - @sizeOf(usize));
                    ptr.* = self.free_stack;
                    self.free_stack = ptr;
                }
                self.active_threads -= 1;
                held.release();
                return system.exitThread(thread.handle);
            }

            // can have more active threads so append it to the thread free list
            thread.next = self.free_thread;
            self.free_thread = thread;
            return held.release();
        }

        const SpawnError = error {
            OutOfStack,
        };

        fn get(self: *Pool, spawn_info: *SpawnInfo) !void {
            spawn_info.node = @fieldParentPtr(Node, "thread_pool", self);
            const held = spawn_info.node.thread_mutex.acquire();
            defer held.release();

            // try popping from the thread free list
            if (self.free_thread) |t| {
                spawn_info.thread = t;
                self.free_thread = t.next;
                return;
            }

            // need to create a new thread, try and get a stack for it
            var is_new_stack = false;
            var stack: ?[]align(Thread.STACK_ALIGN) u8 = null;

            // allocate a stack if custom thread stacks are supported 
            if (system.SUPPORTS_CUSTOM_THREAD_STACKS and self.num_stacks > 0) {
                // try popping from the stack free list
                if (self.free_stack) |s| {
                    const ptr = @ptrToInt(s) - Thread.STACK_SIZE + @sizeOf(usize);
                    stack = @intToPtr([*]align(Thread.STACK_ALIGN) u8, ptr)[0..Thread.STACK_SIZE];
                    self.free_stack = s.*;
                // bump allocate a new stack chunk
                } else if (self.stack_top != 0) {
                    is_new_stack = true;
                    self.stack_top -= 1;
                    const ptr = self.stack_ptr + (self.stack_top * Thread.STACK_SIZE);
                    stack = @intToPtr([*]align(Thread.STACK_ALIGN) u8, ptr)[0..Thread.STACK_SIZE];
                // requires custom stack but none available
                } else {
                    return SpawnError.OutOfStack;
                }
            }

            // restore then newly allocated stack if we failed to create a thread with it
            errdefer if (stack) |s| {
                if (is_new_stack) {
                    self.stack_top += 1;
                } else {
                    const ptr = @ptrCast(?*?*usize, &s[Thread.STACK_SIZE - @sizeOf(usize)]);
                    ptr.* = self.free_stack;
                    self.free_stack = ptr;
                }
            }

            // spawn the thread using the spawn_info
            spawn_info.thread = null;
            spawn_info.stack = if (stack) |s| @ptrToInt(s.ptr) else 0;
            spawn_info.handle = try system.spawnThread(stack, Thread.STACK_SIZE, spawn_info, Thread.entry);
            self.active_threads += 1;
        }
    };
};

const Worker = struct {
    const STACK_ALIGN = 64 * 1024;
    const STACK_SIZE = 1 * 1024 * 1024;

    node: *Node,
    stack_offset: u32,

    fn getStack(self: Worker) []align(STACK_ALIGN) u8 {
        const ptr = @ptrToInt(self.node) + self.stack_offset;
        return @intToPtr([*]align(STACK_ALIGN) u8, ptr)[0..STACK_SIZE];
    }

    fn submit(self: *Worker, task: *Task) void {
        _ = @atomicRmw(usize, self.node.executor.active_tasks, .Add, 1, .Monotonic);
    }

    fn run(self: *Worker) void {

    }
};

const Task = struct {
    next: ?*Task,
    frame: usize,

    const Priority = enum(u2) {
        Low,
        Normal,
        High,
        Root,
    };

    fn init(frame: anyframe, comptime priority: Priority) Task {
        return Task{
            .next = null,
            .frame = @ptrToInt(ptr) | @enumToInt(priority),
        };
    }

    fn getPriority(self: *const Task) Priority {
        return 
    }

    fn prepare(self: *Task, comptime func: var, args: ...) @typeOf(func).ReturnType {
        suspend self.* = Task{
            .next = null,
            .frame = @frame(),
        };
        return func(args);
    }
};