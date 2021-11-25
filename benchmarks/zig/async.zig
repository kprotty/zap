const std = @import("std");
const builtin = @import("builtin");
const ThreadPool = @import("thread_pool");

/// Global thread pool which mimics other async runtimes
var thread_pool: ThreadPool = undefined;

/// Global allocator which mimics other async runtimes
pub var allocator: *std.mem.Allocator = undefined;

/// Zig async wrapper around ThreadPool.Task
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

fn ReturnTypeOf(comptime asyncFn: anytype) type {
    return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
}

/// Entry point for the synchronous main() to an async function.
/// Initializes the global thread pool and allocator 
/// then calls asyncFn(...args) in the thread pool and returns the results.
pub fn run(comptime asyncFn: anytype, args: anytype) ReturnTypeOf(asyncFn) {
    const Args = @TypeOf(args);
    const Wrapper = struct {
        fn entry(task: *Task, fn_args: Args) ReturnTypeOf(asyncFn) {
            // Prepare the task to resume this frame once it's scheduled.
            // Returns execution to after `async Wrapper.entry(&task, args)`.
            suspend {
                task.* = .{ .frame = @frame() };
            }

            // Begin teardown of the thread pool after the entry point async fn completes.
            defer thread_pool.shutdown();

            // Run the entry point async fn
            return @call(.{}, asyncFn, fn_args);
        }
    };

    var task: Task = undefined;
    var frame = async Wrapper.entry(&task, args);

    // On windows, use the process heap allocator.
    // On posix systems, use the libc allocator.
    const is_windows = builtin.target.os.tag == .windows;
    var win_heap: if (is_windows) std.heap.HeapAllocator else void = undefined;
    if (is_windows) {
        win_heap = @TypeOf(win_heap).init();
        win_heap.heap_handle = std.os.windows.kernel32.GetProcessHeap() orelse unreachable;
        allocator = &win_heap.allocator;
    } else if (builtin.link_libc) {
        allocator = std.heap.c_allocator;
    } else {
        @compileError("link to libc with '-Dc' as zig stdlib doesn't provide a fast, libc-less, general purpose allocator (yet)");
    }

    const num_cpus = std.Thread.getCpuCount() catch @panic("failed to get cpu core count");
    const num_threads = std.math.cast(u16, num_cpus) catch std.math.maxInt(u16);
    thread_pool = ThreadPool.init(.{ .max_threads = num_threads });

    // Schedule the task onto the thread pool and wait for the thread pool to be shutdown() by the task.
    task.schedule();
    thread_pool.deinit();
    
    // At this point, all threads in the pool should not be running async tasks
    // so the main task/frame has been completed.
    return nosuspend await frame;
}

/// State synchronization which handles waiting for the result of a spawned async function.
fn SpawnHandle(comptime T: type) type {
    return struct {
        state: std.atomic.Atomic(usize) = std.atomic.Atomic(usize).init(0),

        const Self = @This();
        const DETACHED: usize = 0b1;
        const Waiter = struct {
            task: Task,
            value: T,
        };

        /// Called by the async function to resolve the join() coroutine with the function result.
        /// Returns without doing anything if it was detach()ed.
        pub fn complete(self: *Self, value: T) void {
            // Prepare our waiter node with the value
            var waiter = Waiter{
                .value = value,
                .task = .{ .frame = @frame() },
            };

            // Suspend get ready to wait asynchonously.
            suspend {
                // Acquire barrier to ensuer we see the join()'s *Waiter writes if present.
                // Release barrier to ensure join() and detach() see our *Waiter writes.
                const state = self.state.swap(@ptrToInt(&waiter), .AcqRel);

                // If join() or detach() were called before us.
                if (state != 0) {
                    // Then fill the result value for join() & wake it up.
                    if (state != DETACHED) {
                        const joiner = @intToPtr(*Waiter, state);
                        joiner.value = waiter.value;
                        joiner.task.schedule();
                    }
                    // Also wake ourselves up since there's nothing to wait for.
                    waiter.task.schedule();
                } 
            }
        }

        /// Waits for the async fn to call complete(T) and returns the T given to complete().
        pub fn join(self: *Self) T {
            var waiter = Waiter{
                .value = undefined, // the complete() task will fill this for us
                .task = .{ .frame = @frame() },
            };

            suspend {
                // Acquire barrier to ensuer we see the complete()'s *Waiter writes if present.
                // Release barrier to ensure complete() sees our *Waiter writes.
                if (@intToPtr(?*Waiter, self.state.swap(@ptrToInt(&waiter), .AcqRel))) |completer| {
                    // complete() was waiting for us to consume its value.
                    // Do so and reschedule both of us.
                    waiter.value = completer.value;
                    completer.task.schedule();
                    waiter.task.schedule();
                }
            }

            // Return the waiter value which is either:
            // - consumed by the waiting complete() above or
            // - filled in by complete() when it goes to suspend
            return waiter.value;
        }

        pub fn detach(self: *Self) void {
            // Mark the state as detached, making a subsequent complete() no-op
            // Wake up the waiting complete() if it was there before us.
            // Acquire barrier in order to see the complete()'s *Waiter writes.
            if (@intToPtr(?*Waiter, self.state.swap(DETACHED, .Acquire))) |completer| {
                completer.task.schedule();
            }
        }
    };
}

/// A type-safe wrapper around SpawnHandle() for the spawn() caller.
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

/// Dynamically allocates and runs an async function concurrently to the caller.
/// Returns a handle to the async function which can be used to wait for its result or detach it as a dependency.
pub fn spawn(comptime asyncFn: anytype, args: anytype) JoinHandle(ReturnTypeOf(asyncFn)) {
    const Args = @TypeOf(args);
    const Result = ReturnTypeOf(asyncFn);
    const Wrapper = struct {
        fn entry(spawn_handle_ref: **SpawnHandle(Result), fn_args: Args) void {
            // Create the spawn handle in the @Frame() and return a reference of it to the caller.
            var spawn_handle = SpawnHandle(Result){};
            spawn_handle_ref.* = &spawn_handle;

            // Reschedule the @Frame() so that it can run concurrently from the caller.
            // This returns execution to after `async Wrapper.entry()` down below.
            var task = Task{ .frame = @frame() };
            suspend {
                task.schedule();
            }

            // Run the async function and synchronize the reuslt with the spawn/join handle.
            const result = @call(.{}, asyncFn, fn_args);
            spawn_handle.complete(result);

            // Finally, we deallocate this @Frame() since we're done with it.
            // The `suspend` is there as a trick to avoid a use-after-free:
            //
            // Zig async functions are appended with some code to resume an `await`er if any.
            // That code involves interacting with the Frame's memory which is a no-no once deallocated.
            // To avoid that, we first suspend. This ensures any frame interactions happen befor the suspend-block.
            // This also means that any `await`er would block indefinitely,
            // but that's fine since we're using a custom method with SpawnHandle instead of await to get the value. 
            suspend {
                allocator.destroy(@frame());
            }
        }
    };

    const frame = allocator.create(@Frame(Wrapper.entry)) catch @panic("failed to allocate coroutine");
    var spawn_handle: *SpawnHandle(Result) = undefined;
    frame.* = async Wrapper.entry(&spawn_handle, args);
    return JoinHandle(Result){ .spawn_handle = spawn_handle };
}
