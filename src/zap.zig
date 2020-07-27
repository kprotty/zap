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
        /// The maximum amount of Slots a Pool can contain.
        const MAX_SLOTS = std.math.maxInt(Index) - 1;

        /// Unsigned int type used to index into the Slot slice of a Pool
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

        /// A Slot represents a pointer to data used by a thread to store its pseudo execution state.
        /// A Slot array for each Thread is needed upfront in order to allow lock-free Thread suspend/resume.
        /// Slots are minimized into a single tagged pointer in order to convey as much info as possible with little memory.
        const Slot = struct {
            ptr: usize align(2),

            /// The pointer type which is represented in the Slot.ptr field.
            const Ptr = union(enum) {
                slot: ?*Slot,
                thread: *Thread,
                handle: ?*std.Thread,
                spawning: void,

                /// Convert a Slot.Ptr into a tagged opaque pointer
                fn encode(self: Ptr) usize {
                    return switch (self) {
                        .slot => |ptr| @ptrToInt(ptr) | 0,
                        .thread => |ptr| @ptrToInt(ptr) | 1,
                        .handle => |ptr| @ptrToInt(ptr) | 2,
                        .spawning => |ptr| @ptrToInt(ptr) | 3,
                    };
                }

                /// Convert a tagged opaque pointer into a Slot.Ptr
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
            
            for (slots) |*slot, slot_index| {
                const next_slot_index = @intCast(Index, self.idle_queue >> 16);
                const next_slot = self.indexToSlot(next_slot_index);
                slot.ptr = (Slot.Ptr{ .slot = next_slot }).encode();
                self.idle_queue = @as(usize, @intCast(Index, slot_index + 1)) << 16;
            }

            // Run the threaed pool using this current thread and the current task.
            // Then wait for all threads to finish while deallocating their resources.

            self.push(Task.Batch.from(task));
            self.resumeThread(.{ .no_spawn = true });

            for (slots) |*slot| {
                const slot_ptr = @atomicLoad(usize, &slot.ptr, .Acquire);
                switch (Slot.Ptr.decode(slot_ptr)) {
                    .handle => |handle| {
                        const thread_handle = handle orelse continue;
                        thread_handle.wait();
                        const new_ptr = (Slot.Ptr{ .handle = null }).encode();
                        @atomicStore(usize, &slot.ptr, new_ptr, .Monotonic);
                    },
                    else => |invalid_slot_ptr| {
                        std.debug.panic("Pool.deinit() with invalid slot ptr {}", .{invalid_slot_ptr});
                    },
                }
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

        /// Push a batch of tasks to the pool's run queue in a *wait-free manner.
        /// 
        /// * The algorithm isnt technically wait-free 
        ///   as the queue is detached between the Xchg & the store.
        ///
        /// http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
        fn push(self: *Pool, batch: Task.Batch) void {
            const head = batch.head orelse return;
            const tail = batch.tail;
            const prev = @atomicRmw(*Task, &self.runq_head, .Xchg, tail, .AcqRel);
            @atomicStore(?*Task, &prev.next, head, .Release);
        }

        /// Pop a task from the pool's run queue in a *wait-free manner.
        ///
        /// * The algorithm isn't technically wait-free
        ///   since if a push() detaches the queue as above, this method returns null.
        ///
        /// http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
        fn pop(self: *Pool, runq_tail: **Task) ?*Task {
            var tail = runq_tail.*;
            var next = @atomicLoad(?*Task, &tail.next, .Acquire);

            const stub = @fieldParentPtr(Task, "next", &self.runq_stub);
            if (tail == stub) {
                tail = next orelse return null;
                runq_tail.* = tail;
                next = @atomicLoad(?*Runnable, &tail.next, .Acquire); 
            }

            if (next) |next_tail| {
                runq_tail.* = next_tail;
                return tail;
            }

            const head = @atomicLoad(*Task, &self.head, .Acquire);
            if (head != tail)
                return null;

            self.push(Task.Batch.from(stub));

            next = @atomicLoad(?*Task, &tail.next, .Acquire);
            runq_tail.* = next orelse return null;
            return tail;
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

    /// Check for a task by polling the local run queue of this Thread
    fn pollLocal(self: *Thread) ?*Task {
        // check the runq_next slot first as it's a 1-sized LIFO buffer
        var runq_next = @atomicLoad(?*Task, &self.runq_next, .Monotonic);
        while (runq_next) |next| {
            runq_next = @cmpxchgWeak(
                ?*Task,
                &self.runq_next,
                runq_next,
                null,
                .Monotonic,
                .Monotonic,
            ) orelse return next;
        }

        // check the runq buffer in a FIFO fashion after
        const tail = self.runq_tail;
        var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        while (head != tail) {
            
            const size = tail -% head;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.pollLocal() with invalid runq size of {}", .{size});

            head = @cmpxchgWeak(
                ?*Task,
                &self.runq_head,
                head,
                head +% 1,
                .Monotonic,
                .Monotonic,
            ) orelse return self.runq_buffer[head % self.runq_buffer.len];
        }

        return null;
    }

    /// Check for a task by trying to steal from the run queue of another Thread
    fn pollSteal(self: *Thread, target: *Thread) ?*Task {
        const tail = self.runq_tail;
        const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        if (tail != head)
            std.debug.panic("Thread.pollSteal() when not empty with runq size of {}", .{tail -% head});
        
        // Load target_tail with Acquire barrier to ensure reading valid Task pointers when stealing.
        var target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.runq_tail, .Acquire);

            // handle the case when the target_tail was updated a lot since the last target_head load.
            const target_size = target_tail -% target_head;
            if (target_size > target.runq_buffer.len) {
                target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                continue;
            }

            // prepare to steal half of the target runq's tasks into our own local runq.
            // if the target runq is empty, try to steal from its runq_next slot.
            // if that is also empty, then bail on trying to steal at all.
            //
            // Acquire barrier on runq_next steal to ensure visibility of next's Task writes.
            var steal = target_size - (target_size / 2);
            if (steal == 0) {
                const next = @atomicLoad(?*Task, &target.runq_next, .Monotonic) orelse return null;
                _ = @cmpxchgWeak(
                    ?*Task,
                    &target.runq_next,
                    next,
                    null,
                    .Acquire,
                    .Monotonic,
                ) orelse return next;
                target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                continue;
            }
            
            // Will be returning the first stolen task from the target runq.
            // .Unordered loads are required when reading from remote runq's to avoid LLVM UB.
            steal -= 1;
            var new_tail = tail;
            var new_target_head = target_head +% 1;
            var task_ptr = &target.runq_buffer[target_head % target.runq_buffer.len];
            const first_task = @atomicLoad(*Task, task_ptr, .Unordered);
            
            // Copy the tasks from the target's runq into our runq
            // .Unordered loads are required when reading from remote runq's to avoid LLVM UB.
            // .Unordered stores are required when writing to our runq to avoid LLVM UB on stealer Threads.
            while (steal != 0) : (steal -= 1) {
                task_ptr = &target.runq_buffer[new_target_head % target.runq_buffer.len];
                const task = @atomicLoad(*Task, task_ptr, .Unordered);

                task_ptr = &self.runq_buffer[new_tail % self.runq_buffer.len];
                @atomicStore(*Task, task_ptr, task, .Unordered);

                new_target_head +%= 1;
                new_tail +%= 1;
            }

            // Try to commit the target runq steal by bumping the head position.
            // AcqRel barrier on success is used to ensure two properties:
            // - an Acquire barrier to ensure the tail store below isnt done before the steal actually commits
            // - a Release barrier to ensure that the loads from the target runq arent reordered after the steal commits.
            if (@cmpxchgWeak(
                usize,
                &target.runq_head,
                target_head,
                new_target_head,
                .AcqRel,
                .Monotonic,
            )) |updated_target_head| {
                target_head = updated_target_head;
                continue;
            }

            // Update our runq tail to make the tasks we stole available to be stolen from other Threads.
            // Release barrier to ensure that our local runq writes during the copy are visible to the stealer Threads.
            if (new_tail != tail)
                @atomicStore(usize, &self.runq_tail, new_tail, .Release);
            return first_task;
        }
    }

    /// Check for a task by polling the shared run queue in the Thread Pool
    fn pollGlobal(self: *Thread, pool: *Pool) ?*Task {
        // try to acquire the ability to poll() from the thread pool's run queue
        var runq_tail = blk: {
            var runq_tail = @atomicLoad(usize, &pool.runq_tail, .Monotonic);
            while (runq_tail & IS_POLLING == 0) {
                runq_tail = @cmpxchgWeak(
                    usize,
                    &pool.runq_tail,
                    runq_tail,
                    runq_tail | IS_POLLING,
                    .Acquire,
                    .Monotonic,
                ) orelse break :blk @intToPtr(*Task, runq_tail);
            }
            return false;
        };
        
        // pop one task from the pool's run queue as the first task to return
        var first_task = pool.pop(&runq_tail);
        
        // try to pop a task from the pool runq and store it in our runq_next slot
        // Release barrier to ensure that the task writes are visible to stealer Threads
        if (@atomicLoad(?*Task, &self.runq_next, .Monotonic) == null) {
            while (pool.pop(&runq_tail)) |task| {
                if (first_task == null) {
                    first_task = task;
                } else {
                    @atomicStore(?*Task, &self.runq_next, task, .Release);
                    break;
                }
            }
        }

        // try to pop many tasks from the pool runq and store it in out local runq
        var tail = self.runq_tail;
        var new_tail = tail;
        var head = @atomicLoad(usize, &self.runq_head, .Monotonic);

        while (true) {
            var size = new_tail -% head;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.pollGlobal() with invalid local runq size of {}", .{size});

            // try to pop a task from the pool's run queue if there is room in our local run queue.
            var new_task: ?*Task = null;
            if (size != self.runq_buffer.len)
                new_task = pool.pop(&runq_tail);

            // prepare the new task to be added to our local run queue if there was one.
            // if not, commit the local runq buffer writes we've done so far by updating the tail.
            // after updating the tail, recheck the head to see if tasks were stolen so we can add more.
            //
            // SeqCst barrier on the tail update to ensure two properties:
            // - a Release barrier on the tail for Threads stealing from our runq see updated Task writes
            // - a Full barrier to prevent the head load from being reordered before the tail store.
            //      Release/Acquire barriers on the store/loads respectively is not enough as
            //          Release prevents *other* loads/stores from being reordered after it and
            //          Acquire prevents *other* loads/stores from being reordered before it.
            //      We instead want the store to have an Acquire barrier of sorts, which is what SeqCst provides.
            const task = new_task orelse {
                if (new_tail != tail) {
                    @atomicStore(usize, &self.runq_tail, new_tail, .SeqCst);
                    head = @atomicLoad(usize, &self.runq_head, .Monotonic);
                    tail = new_tail;
                    continue;
                } else {
                    break;
                }
            };

            // .Unordered stores are required when writing to our runq to avoid LLVM UB on stealer Threads.
            if (first_task == null) {
                first_task = task;
            } else {
                @atomicStore(*Task, &self.runq_buffer[new_tail % self.runq_buffer.len], task, .Unordered);
                new_tail +%= 1;
            }
        }

        // try to add a new runq_next if it was stolen during the local buffer adding.
        // Release barrier to ensure that the task writes are visible to stealer Threads.
        if (@atomicLoad(?*Task, &self.runq_next, .Monotonic) == null) {
            while (pool.pop(&runq_tail)) |task| {
                if (first_task == null) {
                    first_task = task;
                } else {
                    @atomicStore(?*Task, &self.runq_next, task, .Release);
                    break;
                }
            }
        }

        // finished polling the thread pool's run queue.
        // release the IS_POLLING lock while at the same time updating the runq_tail.
        @atomicStore(usize, &pool.runq_tail, @ptrToInt(runq_tail), .Release);
        return first_task;
    }

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
                    while (new_tail -% head < BUFFER_SIZE) {
                        task = batch.pop() orelse break;
                        @atomicStore(*Task, &self.runq_buffer[new_tail % BUFFER_SIZE], task, .Unordered);
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

                // Create a batch of tasks out of those stolen from the local runq buffer.
                var overflow_batch = Task.Batch{};
                while (steal != 0) : (steal -= 1) {
                    overflow_batch.pushBack(self.runq_buffer[head % BUFFER_SIZE]);
                    head +%= 1;
                }

                // Update the runq_next if it was stolen while we were creating the batch.
                if (@atomicLoad(?*Task, &self.runq_next, .Monotonic) == null) {
                    const next = overflow_batch.pop();
                    @atomicStore(?*Task, &self.runq_next, next, .Release);
                }
                
                // Combine the local runq batch and the scheduled batch, then push them all to the pool.
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