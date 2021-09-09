const std = @import("std");
const Atomic = std.atomic.Atomic;
const target = std.builtin.target;
const ThreadPool = @import("thread_pool");

var thread_pool: ThreadPool = undefined;

/// A zig async version of ThreadPool.Task
pub const Task = struct {
    tp_task: ThreadPool.Task = .{ .callback = resumeFrame },
    frame: anyframe,

    fn resumeFrame(tp_task: *ThreadPool.Task) void {
        const task = @fieldParentPtr(Task, "tp_task", tp_task);
        resume task.frame;
    }

    pub fn schedule(self: *Task) void {
        thread_pool.schedule(&self.tp_task) catch {};
    }

    pub fn reschedule() void {
        var task = Task{ .frame = @frame() };
        suspend {
            task.schedule();
        }
    }
};

pub var allocator: *std.mem.Allocator = undefined;

/// Use HeapAllocator on windows with the Process Heap.
/// Use a Mutex protected ArenaAllocator on Linux when no libc is available.
var heap_allocator: std.heap.HeapAllocator = undefined;
var arena_lock = std.Thread.Mutex{};
var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var arena_thread_safe_allocator = std.mem.Allocator{
    .allocFn = arena_alloc,
    .resizeFn = arena_resize,
};

fn arena_alloc(_: *std.mem.Allocator, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) std.mem.Allocator.Error![]u8 {
    const held = arena_lock.acquire();
    defer held.release();
    return (arena_allocator.allocator.allocFn)(&arena_allocator.allocator, len, ptr_align, len_align, ret_addr);
} 

fn arena_resize(_: *std.mem.Allocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) std.mem.Allocator.Error!usize {
    const held = arena_lock.acquire();
    defer held.release();
    return (arena_allocator.allocator.resizeFn)(&arena_allocator.allocator, buf, buf_align, new_len, len_align, ret_addr);
}

fn ReturnTypeOf(comptime asyncFn: anytype) type {
    return @typeInfo(@TypeOf(asyncFn)).Fn.return_type orelse unreachable; // function is generic
}

/// Starts the global thread pool and executes the asyncFn with args as the entry point.
/// The thread pool is shut down once asyncFn() completes.
pub fn run(comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
    const Args = @TypeOf(args);
    const Result = ReturnTypeOf(asyncFn);
    const Wrapper = struct {
        fn entry(task: *Task, result: *?Result, fn_args: Args) void {
            suspend {
                task.* = Task{ .frame = @frame() };
            }
            const value = @call(.{}, asyncFn, fn_args);
            result.* = value;
            suspend {
                thread_pool.shutdown();
            }
        }
    };

    // Decide on the allocator. See above
    if (std.builtin.link_libc) {
        allocator = std.heap.c_allocator;
    } else if (target.os.tag == .windows) {
        heap_allocator = @TypeOf(heap_allocator).init();
        heap_allocator.heap_handle = std.os.windows.kernel32.GetProcessHeap() orelse unreachable;
        allocator = &heap_allocator.allocator;
    } else {
        allocator = &arena_thread_safe_allocator;
    }

    // Prepare a Task for the asyncFn
    var task: Task = undefined;
    var result: ?Result = null;
    var frame = async Wrapper.entry(&task, &result, args);

    // Initialize and run the thread pool
    const num_threads = if (std.builtin.single_threaded) 1 else try std.Thread.getCpuCount();
    thread_pool = ThreadPool.init(.{ .max_threads = @intCast(u32, num_threads) });
    thread_pool.schedule(&task.tp_task) catch unreachable;
    thread_pool.deinit();

    // Return the asyncFn result which should be completed
    _ = frame;
    return result orelse error.AsyncFnDeadLocked;
}

const Lock = switch (target.os.tag) {
    .macos, .ios, .tvos, .watchos => DarwinLock,
    .windows => WindowsLock,
    else => switch (target.cpu.arch) {
        .i386, .x86_64 => FutexLockx86,
        else => FutexLock,
    },
};

const WindowsLock = struct {
    srwlock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    pub fn acquire(self: *Lock) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn release(self: *Lock) void {
        std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.srwlock);
    }
};

const DarwinLock = struct {
    oul: std.os.darwin.os_unfair_lock = .{},

    pub fn acquire(self: *Lock) void {
        std.os.darwin.os_unfair_lock_lock(&self.oul);
    }

    pub fn release(self: *Lock) void {
        std.os.darwin.os_unfair_lock_unlock(&self.oul);
    }
};

const FutexLockx86 = struct {
    state: Atomic(u32) = Atomic(u32).init(0),

    pub fn acquire(self: *Lock) void {
        if (self.state.bitSet(0, .Acquire) == 0) |_|
            self.acquireSlow();
    }

    noinline fn acquireSlow(self: *Lock) void {
        var spin: u8 = 100;
        while (spin > 0) : (spin -= 1) {
            std.atomic.spinLoopHint();
            switch (self.state.load(.Monotonic)) {
                0 => if (self.state.tryCompareAndSwap(0, 1, .Acquire, .Monotonic) == 0) return,
                1 => continue,
                else => break,
            }
        }

        while (self.state.swap(2, .Acquire) != 0)
            std.Thread.Futex.wait(&self.state, 2, null) catch unreachable;
    }

    pub fn release(self: *Lock) void {
        if (self.state.swap(0, .Release) == 2)
            std.Thread.Futex.wake(&self.state, 1);
    }
};

const FutexLock = struct {
    state: Atomic(u32) = Atomic(u32).init(0),

    pub fn acquire(self: *Lock) void {
        if (self.state.tryCompareAndSwap(0, 1, .Acquire, .Monotonic)) |_|
            self.acquireSlow();
    }

    noinline fn acquireSlow(self: *Lock) void {
        while (true) : (std.Thread.Futex.wait(&self.state, 2, null) catch unreachable) {
            var state = self.state.load(.Monotonic);
            while (state != 2) {
                state = switch (state) {
                    0 => self.state.tryCompareAndSwap(0, 2, .Acquire, .Monotonic) orelse return,
                    1 => self.state.tryCompareAndSwap(1, 2, .Monotonic, .Monotonic) orelse break,
                    else => unreachable,
                };
            }
        }
    }

    pub fn release(self: *Lock) void {
        if (self.state.swap(0, .Release) == 2)
            std.Thread.Futex.wake(&self.state, 1);
    }
};

pub fn Channel(
    comptime T: type,
    comptime buffer_type: std.fifo.LinearFifoBufferType,
) type {
    return struct {
        queue: VecDeque,
        lock: Lock = .{},
        closed: bool = false,
        readers: ?*Waiter = null,
        writers: ?*Waiter = null,

        const Self = @This();
        const VecDeque = std.fifo.LinearFifo(T, buffer_type);
        const Waiter = struct {
            next: ?*Waiter = null,
            tail: ?*Waiter = null,
            item: error{Closed}!?T,
            task: Task,
        };

        pub usingnamespace switch (buffer_type) {
            .Static => struct {
                pub fn init() Self {
                    return .{ .queue = VecDeque.init() };
                }
            },
            .Slice => struct {
                pub fn init(_buffer: []T) Self {
                    return .{ .queue = VecDeque.init(_buffer) };
                }
            },
            .Dynamic => struct {
                pub fn init(_allocator: *std.mem.Allocator) Self {
                    return .{ .queue = VecDeque.init(_allocator) };
                }
            },
        };

        pub fn deinit(self: *Self) void {
            self.queue.deinit();
            self.* = undefined;
        }

        pub fn close(self: *Self) void {
            self.lock.acquire();
            if (self.closed) {
                return self.lock.release();
            }

            const readers = self.readers;
            self.readers = null;
            
            const writers = self.writers;
            self.writers = null;

            self.closed = true;
            self.lock.release();

            for (&[_]?*Waiter{ readers, writers }) |*waiters| {
                while (waiters.*) |waiter| {
                    waiters.* = waiter.next;
                    waiter.item = error.Closed;
                    waiter.task.schedule();
                }
            }
        }

        pub fn send(self: *Self, item: T) error{Closed}!void {
            self.lock.acquire();

            if (self.closed) {
                self.lock.release();
                return error.Closed;
            }

            if (self.notify(&self.readers, item)) |_| {
                return;
            }

            if (self.queue.writeItem(item)) |_| {
                self.lock.release();
            } else |_| {
                _ = try self.wait(&self.writers, item);
            }
        }

        pub fn recv(self: *Self) error{Closed}!T {
            self.lock.acquire();

            if (self.closed) {
                self.lock.release();
                return error.Closed;
            }

            if (self.notify(&self.writers, null)) |item| {
                return item;
            }

            if (self.queue.readItem()) |item| {
                self.lock.release();
                return item;
            } else {
                const item = try self.wait(&self.readers, null);
                return item orelse unreachable; // sender didn't set item
            }
        }

        fn wait(self: *Self, queue: *?*Waiter, item: ?T) error{Closed}!?T {
            var waiter = Waiter{ .item = item, .task = .{ .frame = @frame() } };
            if (queue.*) |head| {
                head.tail.?.next = &waiter;
                head.tail = &waiter;
            } else {
                queue.* = &waiter;
                waiter.tail = &waiter;
            }

            suspend { self.lock.release(); }
            return waiter.item;
        }

        fn notify(self: *Self, queue: *?*Waiter, item: ?T) ?T {
            const waiter = queue.* orelse return null;
            queue.* = waiter.next;
            if (queue.*) |head|
                head.tail = waiter.tail;
            self.lock.release();

            const waiter_item = waiter.item catch unreachable;
            waiter.item = item;
            waiter.task.schedule();

            return @as(T, waiter_item orelse undefined);
        }
    };
}

