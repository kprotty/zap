const std = @import("std");
const Atomic = std.atomic.Atomic;
const ThreadPool = @import("thread_pool");

var thread_pool: ThreadPool = undefined;
pub var allocator: *std.mem.Allocator = undefined;

const Task = struct {
    tp_task: ThreadPool.Task = .{ .callback = onSchedule },
    frame: anyframe,

    fn onSchedule(tp_task: *ThreadPool.Task) void {
        const task = @fieldParentPtr(Task, "tp_task", tp_task);
        resume task.frame;
    }

    fn schedule(self: *Task) void {
        const batch = ThreadPool.Batch.from(&self.tp_task);
        thread_pool.schedule(batch);
    }
};

pub fn reschedule() void {
    var task = Task{ .frame = @frame() };
    suspend { task.schedule(); }
}

fn ReturnTypeOf(comptime asyncFn: anytype) type {
    return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
}

pub fn run(comptime asyncFn: anytype, args: anytype) ReturnTypeOf(asyncFn) {
    const Args = @TypeOf(args);
    const Wrapper = struct {
        fn entry(task: *Task, fn_args: Args) ReturnTypeOf(asyncFn) {
            suspend { task.* = .{ .frame = @frame() }; }
            defer thread_pool.shutdown();
            return @call(.{}, asyncFn, fn_args);
        }
    };

    var task: Task = undefined;
    var frame = async Wrapper.entry(&task, args);

    const is_windows = std.builtin.target.os.tag == .windows;
    var win_heap: if (is_windows) std.heap.HeapAllocator else void = undefined;
    if (is_windows) {
        win_heap = @TypeOf(win_heap).init();
        win_heap.heap_handle = std.os.windows.kernel32.GetProcessHeap() orelse unreachable;
        allocator = &win_heap.allocator;
    } else if (std.builtin.link_libc) {
        allocator = std.heap.c_allocator;
    } else {
        @compileError("link to libc as zig doesn't provide a fast general purpose allocator yet");
    }

    const num_cpus = std.Thread.getCpuCount() catch @panic("failed to get cpu core count");
    const num_threads = std.math.cast(u16, num_cpus) catch std.math.maxInt(u16);
    thread_pool = ThreadPool.init(.{ .max_threads = num_threads });

    task.schedule();
    thread_pool.deinit();

    return nosuspend await frame;
}

fn SpawnHandle(comptime T: type) type {
    return struct {
        state: Atomic(usize) = Atomic(usize).init(0),

        const Self = @This();
        const Waiter = struct {
            task: Task,
            value: T,
        };

        pub fn complete(self: *Self, value: T) void {
            var w = Waiter{ .value = value, .task = .{ .frame = @frame() } };
            suspend {
                const s = self.state.swap(@ptrToInt(&w), .AcqRel);
                if (s != 0) {
                    if (s != 1) {
                        const joiner = @intToPtr(*Waiter, s);
                        joiner.value = w.value;
                        joiner.task.schedule();
                    }
                    w.task.schedule();
                } 
            }
        }

        pub fn join(self: *Self) T {
            var w = Waiter{ .value = undefined, .task = .{ .frame = @frame() } };
            suspend {
                if (@intToPtr(?*Waiter, self.state.swap(@ptrToInt(&w), .AcqRel))) |completer| {
                    w.value = completer.value;
                    completer.task.schedule();
                    w.task.schedule();
                }
            }
            return w.value;
        }

        pub fn detach(self: *Self) void {
            if (@intToPtr(?*Waiter, self.state.swap(1, .Acquire))) |completer|
                completer.task.schedule();
        }
    };
}

pub fn JoinHandle(comptime T: type) type {
    return struct {
        spawn_handle: *SpawnHandle(T),

        pub fn join(self: @This()) T {
            return self.spawn_handle.join();
        }

        pub fn detach(self: @This()) void {
            return self.spawn_handle.detach();
        }
    };
}

pub fn spawn(comptime asyncFn: anytype, args: anytype) JoinHandle(ReturnTypeOf(asyncFn)) {
    const Args = @TypeOf(args);
    const Result = ReturnTypeOf(asyncFn);
    const Wrapper = struct {
        fn entry(spawn_handle_ref: **SpawnHandle(Result), fn_args: Args) void {
            var spawn_handle = SpawnHandle(Result){};
            spawn_handle_ref.* = &spawn_handle;

            var task = Task{ .frame = @frame() };
            suspend { task.schedule(); }

            const result = @call(.{}, asyncFn, fn_args);
            spawn_handle.complete(result);
            suspend { allocator.destroy(@frame()); }
        }
    };

    const frame = allocator.create(@Frame(Wrapper.entry)) catch @panic("failed to allocate coroutine");
    var spawn_handle: *SpawnHandle(Result) = undefined;
    frame.* = async Wrapper.entry(&spawn_handle, args);
    return JoinHandle(Result){ .spawn_handle = spawn_handle };
}

const WaitQueue = struct {
    const Queue = std.TailQueue(struct {
        address: usize,
        task: Task,
    });

    const Bucket = struct {
        lock: std.Thread.Mutex = .{},
        pending: Atomic(usize) = Atomic(usize).init(0),
        queue: Queue = .{},

        var buckets = [_]Bucket{.{}} ** 256;

        fn from(address: usize) *Bucket {
            const seed: usize = 0x9E3779B97F4A7C15 >> (64 - @bitSizeOf(usize));
            return &buckets[(address *% seed) % buckets.len];
        }
    };

    pub fn wait(address: usize, callback: anytype) void {
        
        const bucket = Bucket.from(address);
        _ = bucket.pending.fetchAdd(1, .SeqCst);

        const held = bucket.lock.acquire();
        if (!callback.shouldWait()) {
            _ = bucket.pending.fetchSub(1, .Monotonic);
            return held.release();
        }
        
        var node: Queue.Node = undefined;
        node.data.task = .{ .frame = @frame() };
        node.data.address = address;

        suspend {
            bucket.queue.append(&node);
            held.release();
        }
    }

    pub fn wake(address: usize, num_waiters: usize) void {
        const bucket = Bucket.from(address);
        if (bucket.pending.load(.SeqCst) == 0)
            return;

        var notified = Queue{};
        defer while (notified.popFirst()) |node|
            node.data.task.schedule();

        const held = bucket.lock.acquire();
        defer held.release();

        var waiters = num_waiters;
        defer if (waiters != num_waiters) {
            _ = bucket.pending.fetchSub(num_waiters - waiters, .Monotonic);
        };

        var queue = bucket.queue.first;
        while (queue) |node| {
            queue = node.next;

            if (node.data.address != address) continue;
            if (waiters == 0) break;
            bucket.queue.remove(node);

            notified.append(node);
            waiters -= 1;
        }
    }
};

pub const WaitGroup = struct {
    count: Atomic(i32) = Atomic(i32).init(0),

    pub fn done(self: *WaitGroup) void {
        return self.add(-1);
    }

    pub fn add(self: *WaitGroup, delta: i32) void {
        var count = self.count.fetchAdd(delta, .SeqCst);
        std.debug.assert(!@addWithOverflow(i32, count, delta, &count));
        std.debug.assert(count >= 0);

        if (count == 0) {
            WaitQueue.wake(@ptrToInt(self), std.math.maxInt(u32));
        }
    }

    pub fn wait(self: *WaitGroup) void {
        const Condition = struct {
            wg: *WaitGroup,

            pub fn shouldWait(cond: @This()) bool {
                return cond.wg.count.load(.SeqCst) != 0;
            }
        };

        var cond = Condition{ .wg = self };
        while (cond.shouldWait()) {
            WaitQueue.wait(@ptrToInt(self), cond);
        }
    }
};
