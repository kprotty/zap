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
        // We don't take advantage of batch scheduling in our benchmarks
        // to keep it fair with other async runtimes ;^)
        const batch = ThreadPool.Batch.from(&self.tp_task);
        thread_pool.schedule(batch);
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

/// Internal handle state to coordinate the result from an async spawned function and its JoinHandle.
fn SpawnHandle(comptime T: type) type {
    return struct {
        state: Atomic(usize) = Atomic(usize).init(0),

        const Self = @This();
        const Waiter = struct {
            value: ?T,
            task: Task,
        };

        /// Called by the thread to mark the handle as completed with the result and possibly wait for join().
        pub fn complete(self: *Self, value: T) void {
            var waiter = Waiter{ .value = value, .task = .{ .task = @frame() } };
            suspend {
                // Acquire barrier ensures we see valid joiner *Waiter if it's waiting.
                // Release barrier ensures detach() and join() see our valid *Waiter we're publishing.
                const state = self.state.swap(@ptrToInt(&waiter), .AcqRel);

                // Non-Zero implies detach() or join() must have been called before, so we don't have to wait.
                // One impmlies detach() was called instead of join() so we don't have to give it our value.
                if (state != 0) {
                    if (state != 1) {
                        const joiner = @intToPtr(*Waiter, state);
                        joiner.value = waiter.value;
                        joiner.task.schedule();
                    }
                    resume @frame();
                }
            }
        }

        pub fn detach(self: *Self) void {
            // Acquire barrier to synchornize with complete() to see valid *Waiter.
            const state = self.state.swap(1, .Acquire);

            // If it's set, the complete() thread is waiting with it's value set
            if (@intToPtr(?*Waiter, state)) |completer| {
                completer.task.schedule();
            }
        }

        pub fn join(self: *Self) T {
            var waiter = Waiter{ .value = null, .task = .{ .task = @frame() } };
            suspend {
                // Acquire barrier ensures we see valid completer *Waiter if it's waiting.
                // Release barrier ensures complete() see our valid *Waiter we're publishing.
                const state = self.state.swap(@ptrToInt(&waiter), .AcqRel);

                // If the completer was already waiting, we just consume it's value.
                // If not, we suspend normally and the future complete() will set our waiter's value.
                if (@intToPtr(?*Waiter, state)) |completer| {
                    waiter.value = completer.value orelse unreachable;
                    completer.task.schedule();
                    resume @frame();
                }
            }
            return waiter.value orelse unreachable;
        }
    };
}

/// A type-safe interface to wait for or detach from an async spawned fn.
pub fn JoinHandle(comptime T: type) type {
    return struct {
        spawn_handle_ref: *SpawnHandle(T),

        pub fn detach(self: @This()) void {
            return self.spawn_handle_ref.detach();
        }

        pub fn join(self: @This()) T {
            return self.spawn_handle_ref.join();
        }
    };
}

/// Runs the async function concurrently to the caller.
/// This can be done without heap allocation at the call-site using Zig async/await, 
/// but we're intentionally heap allocating to make it fair for other langs ;^)
pub fn spawn(comptime asyncFn: anytype, args: anytype) error{OutOfMemory}!JoinHandle(ReturnTypeOf(asyncFn)) {
    const Args = @TypeOf(args);
    const Result = ReturnTypeOf(asyncFn);
    const Wrapper = struct {
        fn entry(spawn_handle_ref: **SpawnHandle(Result), fn_args: Args) void {
            // Create a spawn handle in this frame's memory
            var spawn_handle = SpawnHandle(Result){};
            spawn_handle_ref.* = &spawn_handle;

            // Reschedule the caller to make it concurrent
            var reschedule_task = Task{ .frame = @frame() };
            suspend {
                reschedule_task.schedule();
            }

            // Run the async function and mark the handle as completed (schedules the JoinHandle if joining).
            const result = @call(.{}, asyncFn, fn_args);
            spawn_handle.complete(result);
            
            // Free the current frame with the assumption that it was allocated.
            // This must be done inside a suspend block because the Zig compiler inserts some hidden code
            // at the end of an async function to resume it's `await`er if it has one.
            // This extra code touches the frame memory again so that's a no-no after it's been free'd.
            suspend {
                allocator.destroy(@frame());
            }
        }
    };
    
    // Heap allocate the frame given it has an unbounded lifetime
    const frame = try allocator.create(@Frame(Wrapper.entry));

    // Kick off the async function concurrently and get a reference to it's SpawnHandle
    var spawn_handle_ref: *SpawnHandle(Result) = undefined;
    frame.* = async Wrapper.entry(&spawn_handle_ref, args);

    // Return a join handle which exposes the spawn handle reference.
    return JoinHandle(Result){
        .spawn_handle = spawn_handle_ref,
    };
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
        pub fn send(self: *Self, item: T) error{Shutdown}!void {
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
        pub fn recv(self: *Self) error{Shutdown}!T {
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

