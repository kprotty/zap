const std = @import("std");

pub const Runtime = struct {


};

pub const Task = struct {
    next: ?*Task,
    frame: anyframe,

    /// Hints to the scheduler about how to schedule a Batch of tasks.
    pub const Priority = enum {
        fifo,
        lifo,
    };

    pub fn init(frame: anyframe) Task {
        return Task{
            .next = undefined,
            .frame = frame,
        };
    }

    pub fn schedule(self: *Task, priority: Priority) void {
        return Batch.from(self).schedule(priority);
    }

    /// An ordered set of Task's which can be scheduled together at once.
    pub const Batch = struct {
        head: ?*Task = null,
        tail: *Task = undefined,
        len: usize = 0,

        /// Create a batch of tasks containing only the provided task
        pub fn from(task: *Task) Batch {
            task.next = null;
            return Batch{
                .head = task,
                .tail = task,
                .len = 1,
            };
        }

        /// Alias for `pushBack()`
        pub fn push(self: *Batch, task: *Task) void {
            return self.pushBack(task);
        }

        /// Enqueue a single task to the head-end of this batch.
        pub fn pushFront(self: *Batch, task: *Task) void {
            return self.pushFrontMany(Batch.from(task));
        }

        /// Enqueue a single task to the tail-end of this batch.
        pub fn pushBack(self: *Batch, task: *Task) void {
            return self.pushBackMany(Batch.from(task));
        }

        /// Enqueue a batch of tasks at the head-end of this batch.
        pub fn pushFrontMany(self: *Batch, other: Batch) void {
            const other_head = other.head orelse return;
            if (self.head) |head| {
                other.tail.next = head;
                self.head = other_head;
                self.len += other.len;
            } else {
                self.* = other;
            }
        }

        /// Enqueue a batch of tasks at the tail-end of this batch
        pub fn pushBackMany(self: *Batch, other: Batch) void {
            const other_head = other.head orelse return;
            if (self.head) |head| {
                self.tail.next = other_head;
                self.tail = other.tail;
                self.len += other.len;
            } else {
                self.* = other;
            }
        }

        /// Alias for `popFront()`
        pub fn pop(self: *Batch) ?*Task {
            return self.popFront();
        }

        /// Dequeue and return the head task of the batch
        pub fn popFront(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            self.len -= 1;
            return task;
        }

        /// Schedule the batch of tasks into the currently running thread pool.
        /// Panics if the caller is not running in a task thread pool.
        /// This operation takes ownership of the batch's tasks so it may not be used after.
        pub fn schedule(self: Batch, priority: Priority) void {
            return Thread.getCurrent().schedule(self, priority);
        }
    };

    /// Options used to configure the thread pool which executes async tasks.
    pub const RunOptions = struct {
        /// The maximum amount of threads to use in the thread pool
        /// where the scheduled tasks can execute.
        max_threads: usize = std.math.maxInt(usize),

        /// Allocator used to allocate internal scheduler data structures.
        allocator: *std.mem.Allocator = switch (std.builtin.link_libc) {
            true => std.heap.c_allocator,
            else => std.heap.page_allocator,
        },
    };

    /// Possible errors that could occur when running a task in the thread pool.
    pub const RunError = std.mem.Allocator.Error || error{
        AsyncFnDeadlocked,
    };

    /// Run an async function, and all tasks which it spawns recursively, in a thread pool.
    /// Returns the result of the async fn if it completed and an error if not.
    pub fn run(
        options: RunOptions,
        comptime async_fn: anytype,
        fn_args: anytype,
    ) RunError!@TypeOf(async_fn).ReturnType {
        // wrap the async_fn to run it on the thread pool
        const ArgsType = @TypeOf(fn_args);
        const ReturnType = @TypeOf(async_fn).ReturnType;
        const Wrapper = struct {
            fn call(args: ArgsType, task: *Task, result: *?ReturnType) void {
                suspend task.* = Task.init(@frame());
                const res = @call(.{}, async_fn, args);
                result.* = res;
            }
        };

        // prepare the task for the thread pool which will run the async fn
        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.call(fn_args, &task, &result);
        
        // decide the maximum amount of threads to use for the pool
        var max_threads = std.math.max(1, options.max_threads);
        if (std.builtin.single_threaded) {
            max_threads = 1;
        } else if (std.Thread.cpuCount()) |system_threads| {
            max_threads = std.math.min(system_threads, max_threads);
        } else |_| {}
        max_threads = std.math.min(Thread.Pool.MAX_SLOTS, max_threads);

        // try to allocate the slots on the stack, if possible, to run the thread pool
        const on_stack_slots = std.mem.page_size / 2 / @sizeOf(Thread.Pool.Slot);
        if (max_threads < on_stack_slots) {
            var slots: [on_stack_slots]Thread.Pool.Slot = undefined;
            Thread.Pool.runUsing(slots[0..], &task);
        
        // if not, allocate the slots in the provided allocator to run the thread pool
        } else {
            const allocator = options.allocator;
            const slots = try allocator.alloc(Thread.Pool.Slot, max_threads);
            defer allocator.free(slots);
            Thread.Pool.runUsing(slots, &task);
        }

        // try to return the result of the async fn after the thread pool completes all work.
        // if the result wasn't set, then the async fn ever ran to completion (i.e. deadlock).
        return result orelse RunError.AsyncFnDeadlocked;
    }
};

const Thread = struct {
    const Pool = struct {
        const MAX_SLOTS = std.math.maxInt(Slot.Index) - 1;

        const Slot = struct {
            ptr: usize align(2),

            const Index = @Type(std.builtin.TypeInfo{
                .Int = std.builtin.TypeInfo.Int{
                    .is_signed = false,
                    .bits = switch (std.builtin.arch) {
                        32 => 16,
                        64 => 32,
                        else => @compileError("Architecture not supported"),
                    },
                },
            });

            const Ptr = union(enum) {
                slot: ?*Slot,
                thread: *Thread,
                handle: ?*std.Thread,
                spawning: void,

                fn encode(self: Ptr) usize {
                    return switch (self) {
                        .slot => |ptr| @ptrToInt(ptr) | 0,
                        .thread => |ptr| @ptrToInt(ptr) | 1,
                        .handle => |ptr| @ptrToInt(ptr) | 2,
                        .spawning => |ptr| @ptrToInt(ptr) | 3,
                    };
                }

                fn decode(value: usize) Ptr {
                    const ptr = value & ~@as(usize, 0b11);
                    return switch (value & 0b11) {
                        0 => Ptr{ .slot = @intToPtr(?*Slot, ptr) },
                        1 => Ptr{ .thread = @intToPtr(*Thread, ptr) },
                        2 => Ptr{ .handle = @intToPtr(?*std.Thread, ptr) },
                        3 => Ptr{ .spawning = {} },
                    };
                }
            };
        };

        slots: []Slot,
        runq_stub: ?*Task,
        runq_tail: usize,
        runq_head: *Task,
        idle_queue: usize,
        active_threads: usize,

        const IS_POLLING = 1 << 0;
        const IS_WAKING = 1 << 1;
        const IS_NOTIFIED = 1 << 2;
        const IS_SHUTDOWN = 1 << 3;

        fn runUsing(slots: []Slot, task: *Task) void {
            if (slots.len == 0)
                return;

            // Initialze the thread pool on the stack of the first thread.

            var self = Pool{
                .slots = slots,
                .runq_stub = null,
                .runq_tail = undefined,
                .runq_head = undefined,
                .idle_queue = 0,
                .active_threads = 0,
            };

            const runq_stub = @fieldParentPtr(Task, "next", &self.runq_stub);
            self.runq_tail = @ptrToInt(runq_stub);
            self.runq_head = runq_stub;
            
            for (slots) |*slot, index| {
                const slot_index = self.indexToSlot(self.idle_queue >> 16);
                slot.ptr = (Slot.Ptr{ .slot = slot_index }).encode();
                self.idle_queue = (@intCast(Slot.Index, index + 1)) << 16;
            }

            // Safety checks to make sure the thread pool deinitalized

            const runq_tail = @atomicLoad(usize, &self.runq_tail, .Monotonic);
            const runq_head = @atomicLoad(*Task, &self.runq_head, .Monotonic);
            const idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
            const active_threads = @atomicLoad(usize, &self.active_threads, .Monotonic);

            if (active_threads != 0)
                std.debug.panic("Pool.deinit() with {} active threads", .{active_threads});
            if (idle_queue & IS_SHUTDOWN == 0)
                std.debug.panic("Pool.deinit() when not shutdown", .{});
            if (runq_tail & IS_POLLING != 0)
                std.debug.panic("Pool.deinit() when runq is still polling", .{});
            if (runq_head != runq_stub)
                std.debug.panic("Pool.deinit() when runq is not empty", .{});
        }
    };

    threadlocal var current: ?*Thread = null;

    /// Get a reference to the currently running Pool thread.
    /// Panics if the caller is not running in a thread Pool.
    fn getCurrent() *Thread {
        return Thread.current orelse {
            std.debug.panic("Tried to use a zap function outside it's scheduler", .{});
        };
    }

    ptr: usize,
    handle: ?*std.Thread,
    event: std.ResetEvent,
    runq_next: ?*Task,
    runq_head: usize,
    runq_tail: usize,
    runq_buffer: [256]*Task,

    fn schedule(
        self: *Thread,
        task_batch: Task.Batch,
        priority: Task.Priority,
    ) void {
        var batch = task_batch;
        var task = batch.pop() orelse return;
        const pool = @intToPtr(*Pool, self.ptr);
        
        enqueue: {
            // Try to replace the runq_next slot if fifo scheduling
            // Release ordering on store to ensure stealer Threads read valid frame on runq_next Task.
            if (priority == .lifo) {
                var runq_next = @atomicLoad(?*Task, &self.runq_next, .Monotonic);
                while (true) {
                    const next = runq_next orelse {
                        @atomicStore(?*Task, &self.runq_next, task, .Release);
                        task = batch.pop() orelse break :enqueue;
                        break;
                    };
                    runq_next = @cmpxchgWeak(
                        ?*Task,
                        &self.runq_next,
                        next,
                        task,
                        .Release,
                        .Monotonic,
                    ) orelse {
                        task = next;
                        break;
                    };
                }
            }

            batch.pushFront(task);
            var tail = self.runq_tail;
            var head = @atomicLoad(usize, &self.runq_head, .Monotonic);

            const BUFFER_SIZE = self.runq_buffer.len;
            while (true) {
                const size = tail -% head;
                if (size > BUFFER_SIZE)
                    std.debug.panic("Thread.schedule() with invalid runq size of {}", .{size});

                // check if theres space in the local runq buffer to push the batch tasks to
                if (batch.len <= (BUFFER_SIZE - size)) {
                    var new_tail = tail;
                    while (tail -% head < BUFFER_SIZE) {
                        self.runq_buffer[new_tail % BUFFER_SIZE] = batch.pop() orelse break;
                        new_tail +%= 1;
                    }

                    // only do a store if tasks were pushed to the runq buffer.
                    // Release barrier to ensure stealer Threads read value Tasks from our runq_buffer.
                    if (new_tail != tail) {
                        tail = new_tail;
                        @atomicStore(usize, &self.runq_tail, new_tail, .Release);
                    }

                    // handle the remaining batch tasks if there are any.
                    if (batch.len == 0) {
                        break :enqueue;
                    } else {
                        head = @atomicLoad(usize, &self.runq_head, .Monotonic);
                        continue;
                    }
                }

                // The batch hash more tasks than the runq buffer could affort to take.
                // try to steal half of the buffers tasks in order to overflow them into the pool runq.
                var steal: usize = BUFFER_SIZE / 2;
                if (@cmpxchgWeak(
                    usize,
                    &self.runq_head,
                    head,
                    head +% steal,
                    .Monotonic,
                    .Monotonic,
                )) |new_head| {
                    head = new_head;
                    continue;
                }

                var overflow_batch = Task.Batch{};
                while (steal != 0) : (steal -= 1) {
                    overflow_batch.pushBack(self.runq_buffer[head % BUFFER_SIZE]);
                    head +%= 1;
                }

                overflow_batch.pushBackMany(batch);
                pool.push(overflow_batch);
                break :enqueue;
            }
        }

        // Tasks were scheduled into either our Thread or our Pool.
        // Try to wake up another thread in order to handle these new tasks.
        pool.resumeThread(.{});
    }
};