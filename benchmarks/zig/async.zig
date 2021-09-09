const std = @import("std");
const Atomic = std.atomic.Atomic;
const target = std.builtin.target;
const Lock = @import("lock.zig").Lock;
const ThreadPool = @import("thread_pool");

// Global thread pool instance used for async stuff
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
        return Batch.from(self).schedule();
    }
};

/// Batch of async tasks that can be scheduled
pub const Batch = struct {
    tp_batch: ThreadPool.Batch = .{},

    pub fn from(batchable: anytype) Batch {
        return switch (@TypeOf(batchable)) {
            *Task => .{ .tp_batch = ThreadPool.Batch.from(&batchable.tp_task) },
            Batch => batchable,
            else => |T| @compileError(@typeName(T) ++ " isn't batchable"),
        };
    }

    pub fn push(self: *Batch, batchable: anytype) void {
        const batch = from(batchable);
        return self.tp_batch.push(batch.tp_batch);
    }

    pub fn schedule(self: Batch) void {
        thread_pool.schedule(self.tp_batch);
    }
};

/// Global allocator used for async stuff
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
    task.schedule();
    thread_pool.deinit();

    // Return the asyncFn result which should be completed
    _ = frame;
    return result orelse error.AsyncFnDeadLocked;
}

/// MPMC channel capable of bounded/unbounded send()/recv().
pub fn Channel(
    comptime T: type,
    comptime buffer_type: std.fifo.LinearFifoBufferType,
) type {
    return struct {
        queue: VecDeque,
        lock: Lock = .{},
        readers: ?*Waiter = null,
        writers: ?*Waiter = null,
        is_shutdown: bool = false,

        const Self = @This();
        const VecDeque = std.fifo.LinearFifo(T, buffer_type);
        const Waiter = struct {
            next: ?*Waiter = null,
            tail: ?*Waiter = null,
            item: error{Shutdown}!?T,
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

        /// Closes both the read and write ends of the channel
        /// making future send() and recv() calls return `error.Shutdown`. 
        pub fn close(self: *Self) void {
            self.lock.acquire();
            if (self.is_shutdown) {
                return self.lock.release();
            }

            const readers = self.readers;
            self.readers = null;
            
            const writers = self.writers;
            self.writers = null;

            self.is_shutdown = true;
            self.lock.release();

            for (&[_]?*Waiter{ readers, writers }) |*waiters| {
                while (waiters.*) |waiter| {
                    waiters.* = waiter.next;
                    waiter.item = error.Shutdown;
                    waiter.task.schedule();
                }
            }
        }

        /// Pushes the item to the channel, blocking the caller asynchronously until it can.
        /// Returns error.Shutdown if shutdown() was ever called on the Channel.
        pub fn send(self: *Self, item: T) !void {
            self.lock.acquire();

            if (self.is_shutdown) {
                self.lock.release();
                return error.Shutdown;
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

        /// Pops an item from the channel, blocking the caller asynchronously until it can.
        /// Returns error.Shutdown if shutdown() was ever called on the Channel.
        pub fn recv(self: *Self) !T {
            self.lock.acquire();

            if (self.is_shutdown) {
                self.lock.release();
                return error.Shutdown;
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
        
        /// Block asynchronously on either `readers` or `writers` queue until notified with an item.
        /// Stores the given item in our waiter if the caller is from send().
        fn wait(self: *Self, queue: *?*Waiter, item: ?T) error{Shutdown}!?T {
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

        /// Try to unblock an asynchronous task waiting on either `readers` or `writers` queue with an item.
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

