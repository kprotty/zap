// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");

pub const Task = extern struct {
    next: ?*Task = undefined,
    continuation: usize,
    
    const IS_FRAME = 1;

    /// Initialize a Task which will resume an async frame when scheduled.
    pub fn init(frame: anyframe) Task {
        return Task{ .continuation = @ptrToInt(frame) | IS_FRAME };
    }

    /// The callback function type which represents the task continuation.
    /// Takes in the thread for cases where tls_current isnt required (i.e. in C).
    /// tls_current may not be necessary in the future for zig async as well if it ever gets resume arguments?
    pub const Callbackfn = fn(*Task, *Thread) callconv(.C) void;

    /// Initialize a Task which will invoke the callback when scheduled
    pub fn initCallback(callback: CallbackFn) Task {
        return Task{ .continuation = @ptrToInt(callback) };
    }

    fn execute(self: *Task, thread: *Thread) void {
        // Since this is a hot-path functions, we should get rid of any checks when decoding the continuation.
        // These have proven to have enough overhead for the execution of very small tasks.

        if (self.continuation & IS_FRAME != 0) {
            const frame = blk: {
                @setRuntimeSafety(false);
                break :blk @intToPtr(anyframe, self.continuation & ~@as(usize, IS_FRAME));
            };
            resume frame;
            return;
        }

        const callback_fn = blk: {
            @setRuntimeSafety(false);
            break :blk @intToPtr(CallbackFn, self.continuation);
        };
        (callback_fn)(self, thread);
    }

    pub const ScheduleHint = struct {
        fifo: bool = false,
    };

    pub fn schedule(self: *Task, hint: ScheduleHint) void {
        self.toBatch().schedule(hint);
    }

    pub fn fork() void {
        var task = Task.init(@frame());
        suspend task.schedule(.{});
    }

    pub fn yield() void {
        var task = Task.init(@frame());
        suspend task.schedule(.{ .fifo = true });
    }

    pub fn shutdown() void {
        const thread = Thread.getCurrent();
        const scheduler = thread.getScheduler();
        scheduler.shutdown();
    }

    /// Convert a single Task to a Batch containing only that one Task
    pub fn toBatch(self: *Task) Batch {
        self.next = null;
        return Batch{
            .head = self,
            .tail = self,
        };
    }

    /// An ordered set of Tasks objects which are scheduled as a unit together.
    pub const Batch = extern struct {
        head: ?*Task = null,
        tail: *Task = undefined,
        
        /// Returns true if the Batch contains no Tasks
        pub fn isEmpty(self: Batch) bool {
            return self.head == null;
        }

        /// Push the task to the Batch, defaulting to FIFO ordering.
        /// This takes ownership of the Task until its consumed/popped.
        pub fn push(self: *Batch, task: *Task) void {
            self.pushManyBack(task.toBatch());
        }

        /// Push a batch of tasks to the front of this batch, consuming the pushed batch.
        pub fn pushManyFront(self: *Batch, batch: Batch) void {
            if (self.isEmpty()) {
                self.* = batch;
            } else if (!batch.isEmpty()) {
                batch.tail.next = self.head;
                self.head = batch.head;
            }
        }

        /// Push a batch of tasks to the back of this batch, consuming the pushed batch.
        pub fn pushManyBack(self: *Batch, batch: Batch) void {
            if (self.isEmpty()) {
                self.* = batch;
            } else if (!batch.isEmpty()) {
                self.tail.next = batch.head;
                self.tail = batch.tail;
            }
        }

        /// Pop a task from the queue, taking ownership of the dequeued task.
        /// This dequeues in a FIFO manner.
        pub fn pop(self: *Batch) ?*Task {
            return self.popFront();
        }

        /// Pop a task from the front queue, taking ownership when dequeued. 
        pub fn popFront(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            return task;
        }

        /// Schedule this batch of operations onto the current running Thread/Scheduler.
        /// This must be called from a function running inside the the Scheduler.
        /// this also consumes the Batch so it should no longer be used after this operation.
        pub fn schedule(self: Batch, hint: ScheduleHint) void {
            if (self.isEmpty())
                return;

            const thread = Thread.getCurrent();
            thread.schedule(self, hint);
        }
    };

    pub const RunConfig = struct {
        threads: usize = 0,
        allocator: ?*std.mem.Allocator = null,
    };

    /// Get the return type of a function.
    /// Sad that this isnt in `std.meta`
    fn ReturnTypeOf(comptime asyncFn: anytype) type {
        return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
    }

    /// Run an async function by starting up a task scheduler.
    /// Once the asyncFn completes, then shutdown the scheduler.
    pub fn runAsync(
        run_config: RunConfig,
        comptime asyncFn: anytype,
        args: anytype,
    ) !ReturnTypeOf(asyncFn) {
        return runAsyncWithShutdown(true, run_config, asyncFn, args);
    }

    /// Run an async function by starting up a task scheduler.
    /// Unlike `runAsync`, the scheduler keeps running until its shutdown manually via `Task.shutdown()`.
    pub fn runAsyncUntilShutdown(
        run_config: RunConfig,
        comptime asyncFn: anytype,
        args: anytype,
    ) !ReturnTypeOf(asyncFn) {
        return runAsyncWithShutdown(false, run_config, asyncFn, args);
    }

    /// Start the task scheduler using the provided asyncFn as the entry point.
    /// After the asyncFn completes, then shutdown the scheduler if desired by `shutdown_after`.
    fn runAsyncWithShutdown(
        comptime shutdown_after: bool,
        run_config: RunConfig,
        comptime asyncFn: anytype,
        args: anytype, 
    ) !ReturnTypeOf(asyncFn) {
        // wrap the task so that it immediately suspends in order to make a Task for it.
        // suspend at completion when storing the result as it doesnt need to run the compiler-inserted async exit code.
        const Wrapper = struct {
            fn entry(fn_args: anytype, task: *Task, ret: *?ReturnTypeOf(asyncFn)) void {
                suspend task.* = Task.init(@frame());
                const result = @call(.{}, asyncFn, fn_args);
                suspend {
                    ret.* = result;
                    if (shutdown_after) {
                        Task.shutdown();
                    }
                }
            }
        };

        var task: Task = undefined;
        var result: ?ReturnTypeOf(asyncFn) = null;
        var frame = async Wrapper.entry(args, &task, &result);
        
        // create a Task for the async function and use that to run.
        try task.runUntilShutdown(run_config);

        // if theres no result, then the async function never set it so it didn't complete
        return result orelse error.AsyncFnDeadLocked;
    }

    pub fn runUntilShutdown(self: *Task, run_config: RunConfig) !void {
        const num_workers = blk: {
            if (std.builtin.single_threaded)
                break :blk 1;
            if (run_config.threads > 0)
                break :blk run_config.threads;
            break :blk (std.Thread.cpuCount() catch 1);
        };

        // small worker count optimization
        const stack_workers = 2048 / @sizeOf(Worker);
        if (num_workers <= stack_workers) {
            var workers: [stack_workers]Worker = undefined;
            return self.runUntilShutdownWithWorkers(workers[0..]);
        }

        const allocator = blk: {
            if (run_config.allocator) |allocator|
                break :blk allocator;
            if (std.builtin.link_libc)
                break :blk std.heap.c_allocator;
            break :blk std.heap.page_allocator;
        };

        // the only instance of the allocator usage
        const workers = allocator.alloc(Worker, num_workers);
        defer allocator.free(workers);
        return self.runUntilShutdownWithWorkers(workers);
    }

    pub fn runUntilShutdownWithWorkers(self: *Task, workers: []Worker) !void {
        return Scheduler.run(self, workers);
    }

    /// Hint to the CPU that it can yield its hardware thread if need be.
    fn spinLoopHint() void {
        std.SpinLock.loopHint(1);
    }

    pub const Worker = struct {
        ptr: usize,

        const Ptr = union(enum) {
            idle: u16,
            spawning: ?*std.Thread,
            running: *Thread,
            shutdown: ?*std.Thread,

            fn fromUsize(value: usize) Ptr {
                if (std.meta.alignment(*std.Thread) < 4)
                    @compileError("Platform does not support pointer tagging to this granularity");

                return switch (value & 0b11) {
                    0 => Ptr{ .idle = @truncate(u16, value >> 2) },
                    1 => Ptr{ .spawning = @intToPtr(?*std.Thread, value & ~@as(usize, 0b11)) },
                    2 => Ptr{ .running = @intToPtr(*Thread, value & ~@as(usize, 0b11)) },
                    3 => Ptr{ .shutdown = @intToPtr(?*std.Thread, value & ~@as(usize, 0b11)) },
                    else => unreachable,
                };
            }

            fn toUsize(self: Ptr) usize {
                return switch (self) {
                    .idle => |index| (@as(usize, index) << 2) | 0,
                    .spawning => |handle| (@ptrToInt(handle) << 2) | 1,
                    .running => |thread| (@ptrToInt(thread) << 2) | 2,
                    .shutdown => |handle| (@ptrToInt(handle) << 2) | 3,
                };
            }
        };
    };

    pub const Scheduler = struct {
        workers: []Worker,
        run_queue: ?*Task,
        idle_queue: u32,
        
        fn run(task: *Task, workers: []Worker) void {
            // limit the workers so that they fit in Scheduler.idle_queue as indices
            const max_workers = std.math.maxInt(u16) - 1;
            const num_workers = @intCast(u16, std.math.min(max_workers, workers.len));
            if (num_workers == 0)
                return;

            // in order to run the workers, we need a Scheduler. allocate it on the stack
            var self = Scheduler {
                .run_queue = null,
                .idle_queue = 0,
                .workers = workers[0..num_workers],
            };

            // safety checks on cleanup
            defer if (std.debug.runtime_safety) {
                const idle_queue = @atomicLoad(u32, &self.idle_queue, .Monotonic);
                if (idle_queue != IDLE_SHUTDOWN)
                    unreachable; // Scheduler exit when idle queue isn't shutdown

                const run_queue = @atomicLoad(?*Task, &self.run_queue, .Monotonic);
                if (run_queue != null)
                    unreachable; // Scheduler exit when run queue isn't empty
            }

            // link the worker indices together to form a stack where idle_queue references the top index
            self.idle_queue = num_workers;
            for (self.workers) |*worker, index| {
                worker.* = Worker{ .ptr = Worker.Ptr{ .idle = index } };
            }

            // schedule the task and run a worker thread (using the caller/main thread)
            self.push(task.toBatch());
            self.resumeThread(.{ .use_caller = true });

            // for all the std.Thread's that we spawned, wait for them to complete
            for (self.workers) |*worker| {
                const worker_ptr_value = @atomicLoad(usize, &worker.ptr, .Acquire);
                switch (Worker.Ptr.fromUsize(worker_ptr_value)) {
                    .handle => |thread_handle| {
                        if (thread_handle) |handle| {
                            handle.wait();
                        }
                    },
                    else => unreachable,
                }
            }
        }

        /// Schedule a batch of Tasks to the scheduler from outside a scheduler Thread.
        pub fn schedule(self: *Scheduler, batch: Batch) void {
            if (batch.isEmpty())
                return;

            self.push(batch);
            self.resumeThread(.{});
        }
        
        /// Push a batch of tasks onto the Scheduler's run queue
        fn push(self: *Scheduler, batch: Batch) void {
            if (batch.isEmpty())
                return;

            // Simple lock-free stack push
            // Release memory ordering on success to make the task writes visible to other threads when published
            var run_queue = @atomicLoad(?*Task, &self.run_queue, .Monotonic);
            while (true) {

                batch.tail.next = run_queue;
                const new_run_queue = batch.head;

                run_queue = @cmpxchgWeak(
                    ?*Task,
                    &self.run_queue,
                    run_queue,
                    new_run_queue,
                    .Release,
                    .Monotonic,
                ) orelse return;
            }
        }

        const IDLE_NOTIFIED = 1;
        const IDLE_SHUTDOWN = std.math.maxInt(u32);

        const ResumeConfig = struct {
            use_caller: bool = false,
            is_waking: bool = false,
        };

        const ResumeType = union(enum) {
            spawned: u16,
            resumed: *Thread,
            notified: void,
        };

        fn resumeThread(self: *Scheduler, resume_config: ResumeConfig) void {
            const workers = self.workers;
            var resume_type: ResumeType = undefined;

            while (true) : (spinLoopHint()) {
                const idle_queue = @atomicLoad(u32, &self.idle_queue, .Acquire);

                // bail if the scheduler is already shutdown
                if (idle_queue == IDLE_SHUTDOWN)
                    return;

                var worker_index = @truncate(u16, idle_queue >> 16);
                var aba_tag = @truncate(u15, idle_queue >> 1);
                var is_notified = idle_queue & IDLE_NOTIFIED != 0;
                
                // if the idle queue is empty, we should leave a notification that we tried to resume().
                // if not, we could resume(), a thread could suspend(), and then miss our resume request.
                if (worker_index == 0) {
                    // if the idle queue is already notified, nothing more we can do
                    if (is_notified)
                        return;
                    is_notified = true;
                    resume_type = ResumeType{ .notified = {} };

                // handle the case where theres workers on the idle queue to wake up.
                } else {
                    // if the idle queue is notified, it means theres a Thread in the process of waking.
                    // we shouldn't wake up more threads while a Thread is waking as that would just increase contention.
                    //
                    // if we're the waking thread (resume_config.is_waking) and we call resume() it means we found a task.
                    // a waking thread stops waking either if it found a task after being resumed or it found nothing and suspended.
                    // If we're the waking thread and we're resuming (we found a task) then we should keep the notified and wake another thread.
                    if (is_notified and !resume_config.is_waking) {
                        return;
                    } else {
                        is_notified = true;
                    }

                    const worker = &workers[worker_index - 1];
                    var worker_ptr = @atomicLoad(usize, &worker.ptr, .Acquire);
                    switch (Worker.Ptr.fromUsize(worker_ptr)) {
                        // the worker isnt associated with a thread yet so we should spawn a new one
                        .idle => |next_index| {
                            resume_type = ResumeType{ .spawned = worker_index - 1 };
                            worker_index = next_index;
                        },
                        // the worker is being resumed on another thread so our idle_queue is outdated
                        .spawning => {
                            continue;
                        },
                        // the worker has a running thread, use the thread's next_worker index for the idle_queue link
                        .running => |thread| {
                            resume_type = ResumeType{ .resumed = thread };
                            worker_index = @atomicLoad(u16, &thread.worker_state, .Unordered);
                        },
                        // the worker should not be shutdown while another worker is running (e.g. calling resume())
                        .shutdown => {
                            unreachable; // worker shutdown when trying to resume it
                        },
                    }
                }

                var new_idle_queue: u32 = 0;
                new_idle_queue |= @boolToInt(is_notified);
                new_idle_queue |= @as(u32, aba_tag) << 1;
                new_idle_queue |= @as(u32, worker_index) << 16;

                _ = @cmpxchgWeak(
                    u32,
                    &self.idle_queue,
                    idle_queue,
                    new_idle_queue,
                    .Acquire,
                    .Acquire,
                ) orelse break;
            }

            // If we need to wake up a thread, do so
            // Else we need to spawn a new thread using the worker
            const worker_index = switch (resume_type) {
                .notified => {
                    return;
                },
                .spawned => |worker_index| {
                    const worker_ptr_value = (Worker.Ptr{ .spawning = null }).toUsize();
                    @atomicStore(usize, &workers[worker_index].ptr, worker_ptr_value, .Monotonic);
                    break :blk worker_index;
                },
                .resumed => |thread| {
                    @atomicStore(u16, &thread.worker_state, Thread.IS_WAKING, .Unordered);
                    thread.notify();
                    return;
                },
            };

            const spawn_info = Thread.SpawnInfo{
                .scheduler = self,
                .worker_index = worker_index,
            };

            // If provided, use the callers stack/OS-thread to run the worker Thread instead of spawning a new one
            if (resume_config.use_caller) {
                Thread.run(spawn_info);
                return;
            } else if (std.builtin.single_threaded) {
                unreachable;
            }

            // Spawn a Thread using the worker info.
            // Atomically update the worker ptr with the thread handle if it hasn't changed.
            // If it did change, then it changed to the *Thread itself, so set the thread handle directly onto it.
            if (std.Thread.spawn(
                spawn_info,
                Thread.run,
            )) |thread_handle| {
                const worker_ptr = @cmpxchgStrong(
                    usize,
                    &workers[worker_index].ptr,
                    (Worker.Ptr{ .spawning = null }).toUsize(),
                    (Worker.Ptr{ .spawning = thread_handle }).toUsize(),
                    .Acquire,
                    .Acquire,
                ) orelse return;
                switch (Worker.Ptr.fromUsize(worker_ptr)) {
                    .idle => unreachable, // worker still idle when spawning a thread for it
                    .shutdown => unreachable, // worker shutdown when trying to spawn with it
                    .spawning => return, // we spawned the thread, our task is complete,
                    .running => |thread| {
                        thread.handle = thread_handle;
                        return;
                    },
                }
            } else |err| {}

            // We failed to spawn an OS thread for this Worker, backtrack our updates
            // Add the worker back to the idle queue stack
            var idle_queue = @atomicLoad(u32, &self.idle_queue, .Monotonic);
            while (true) {
                var next_worker_index = @truncate(u16, idle_queue >> 16);
                var aba_tag = @truncate(u15, idle_queue >> 1);
                var is_notified = idle_queue & IDLE_NOTIFIED != 0;
                
                // Link the worker to point to the top worker index of the idle queue.
                // Unset the notified bit since we were suppose to have this thread be the waking thread.
                // Then increment the aba tag since its needs to be bumped on every push to the idle queue to be useful.
                const worker_ptr = (Worker.Ptr{ .idle = next_worker_index }).toUsize();
                @atomicStore(usize, &workers[worker_index].ptr, worker_ptr, .Unordered);
                next_worker_index = worker_index + 1;
                is_notified = false;
                aba_tag +%= 1;

                var new_idle_queue: u32 = 0;
                new_idle_queue |= @boolToInt(is_notified);
                new_idle_queue |= @as(u32, aba_tag) << 1;
                new_idle_queue |= @as(u32, worker_index) << 16;

                // Once we push the worker back to the idle queue, we return as a failed resume() operation.
                // Release memory ordering on success to ensure that the worker store above is visible on othe resuming threads.
                _ = @cmpxchgWeak(
                    u32,
                    &self.idle_queue,
                    idle_queue,
                    new_idle_queue,
                    .Release,
                    .Monotonic,
                ) orelse return;
            }
        }

        pub fn shutdown(self: *Scheduler) void {
            const idle_queue = @atomicRmw(u32, &self.idle_queue, .Xchg, IDLE_SHUTDOWN, .AcqRel);
            if (idle_queue == IDLE_SHUTDOWN)
                return;

            var worker_index = @truncate(u6, idle_queue >> 16);
            while (worker_index != 0) {
                
            }
        }
    };

    pub const Thread = struct {
        runq_head: u8,
        runq_tail: u8,
        runq_next: ?*Task,
        runq_overflow: ?*Task,
        run_queue: [256]*Task,
        scheduler: ?*Scheduler,
        handle: ?*std.Thread,
        worker_index: u16,
        worker_state: u16,
        xorshift: u32,

        const IS_RUNNING = 0;
        const IS_WAKING = 1;
        const IS_SHUTDOWN = 2;

        const SpawnInfo = struct {
            scheduler: *Scheduler,
            worker_index: u16,
        };

        // the entry point for a worker thread in the Scheduler 
        fn run(spawn_info: SpawnInfo) void {
            const scheduler = spawn_info.scheduler;
            const worker_index = spawn_info.worker_index;
            
            // allocate the Thread object on the OS thread's stack.
            var self = Thread {
                .runq_head = 0,
                .runq_tail = 0,
                .runq_overflow = null,
                .run_queue = buffer,
                .scheduler = scheduler,
                .handle = null,
                .worker_index = worker_index,
                .worker_state = IS_WAKING,
                .xorshift = seed: {
                    var ptr = @ptrToInt(scheduler) + worker_index;
                    ptr = (13 * ptr) ^ (ptr >> 15);
                    break :seed @truncate(u32, ptr);
                },
            };

            // Ensure that the tls_current points to our thread.
            // Restore the old value to support nested threads running if that ever needs to happen.
            const old_tls_current = tls_current;
            tls_current = &self;
            defer tls_current = old_tls_current;

            {
                // The worker.ptr should be a Ptr{ .spawning = ?*std.Thread }
                // We swap it with Ptr{ .running = *Thread } to indicate to other workers that our thread is ready & running.
                // If the spawning ?*std.Thread is not null, then the spawner set it first so we store it in our .handle field.
                // If its null, then we updated the worker ptr first so the spawner will see our Thread ptr and store the .handle field itself.
                //
                // An Acquire-Release (AcqRel) barrier is used for the swap operation:
                // - Acquire barrier to ensure valid pointer writes to the *std.Thread if there is any
                // - Release barrier to ensure other threads see our Thread writes above when seeing that we're running (using an Acquire load).
                const worker = &scheduler.workers[worker_index];
                const worker_ptr_value = (Worker.Ptr{ .running = &self }).toUsize();
                const new_worker_ptr_value = @atomicRmw(usize, worker.ptr, .Xchg, worker_ptr_value, .AcqRel);

                switch (Worker.Ptr.fromUsize(new_worker_ptr_value)) {
                    .idle => unreachable, // the worker should be spawning 
                    .running => unreachable, // the worker shouldn't be associated with another thread but ours
                    .shutdown => unreachable, // our thread is just started, the worker shouldn't be finishing
                    .spawning => |thread_handle_ptr| {
                        if (@intToPtr(?*std.Thread, thread_handle_ptr)) |thread_handle| {
                            self.handle = thread_handle;
                        }
                    }
                }
            }

            // Safety checks on cleanup 
            defer if (std.debug.runtime_safety) {
                const runq_tail = self.runq_tail;
                const runq_head = @atomicLoad(u8, &self.runq_head, .Monotonic);
                if (runq_tail != runq_head)
                   unreachable; // Thread exit with run_queue is not empty

                const runq_overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
                if (runq_overflow != null)
                    unreachable; // Thread exit with non empty runq overflow

                const runq_next = @atomicLoad(?*Task, &self.runq_next, .Monotonic);
                if (runq_next != null)
                    unreachable; // Thread exit with non empty runq next
            }

            while (true) {
                if (self.pop()) |task| {
                    task.execute();
                    continue;
                }

                if (!scheduler.suspendThread(&self))
                    return;

                switch (@atomicLoad(u16, &self.worker_state, .Unordered)) {
                    IS_RUNNING => {}, // we consumed a notification left behind from a Scheduler.resumeThread()
                    IS_WAKING => {}, // we were woken up by someone calling Scheduler.resumeThread() 
                    IS_SHUTDOWN => break, // we were woken up from a Scheduler.shutdown() request
                    else => unreachable, // Thread woke up with an invalid worker_state
                }
            }
        }

        threadlocal var tls_current: ?*Thread = null;

        /// Get a reference to current thread.
        /// This goes through the thread local above as zig async doesnt have resume arguments / poll contexes.
        pub fn getCurrent() *Thread {
            return tls_current orelse unreachable; // Caller not running inside a Scheduelr thread
        }

        /// Return the scheduler that this thread belongs to.
        pub fn getScheduler() *Scheduler {
            return self.scheduler;
        }

        /// Schedule a batch of tasks for execution available to the Scheduler that this Thread is apart of.
        pub fn schedule(self: *Thread, batch: Batch, hint: ScheduleHint) void {
            if (batch.isEmpty())
                return;

            self.push(batch, !hint.fifo);
            self.getScheduler().resumeThread(.{});
        }

        /// Push a batch of tasks to the local run queues of the caller Thread.
        /// When tasks are made available to other threads there is a Release memory barrier.
        /// That it to ensure the Task writes (e.g. the continuation) is correctly read when its stolen.
        fn push(self: *Thread, batch: Batch, push_next: bool) void {
            var tasks = batch;
            var tail = self.runq_tail;

            while (!tasks.isEmpty()) {
                // Try to push to the "next" slot of the run queue which is polled first as a LIFO mechanism 
                if (push_next) {
                    if (@atomicLoad(?*Task, &self.runq_next, .Monotonic) == null) {
                        const next = tasks.pop().?;
                        @atomicStore(?*Task, &self.runq_next, next, .Release);
                        continue;
                    }
                }

                // Push to the local run_queue buffer if its not empty.
                var head = @atomicLoad(u8, &self.runq_head, .Monotonic);
                const size = tail -% head;
                var remaining = self.run_queue.len - size;
                if (remaining != 0) {

                    while (remaining != 0) : (remaining -= 1) {
                        const task = tasks.pop() orelse break;
                        @atomicStore(*Task, &self.run_queue[tail % self.run_queue.len], task, .Unordered);
                        overflowed.push(task);;
                        tail +%= 1;
                        break :blk overflowed;
                    }

                    @atomicStore(u8, &self.runq_tail, tail, .Release);
                    continue;
                }

                // The run_queue buffer is full, try to move half of it to the overflow queue.
                // This will make future pushes go through the fast path above.
                // The fast path to the buffer only requires an atomic store while this path requires cmpxchg.
                // Atomic loads/stores to aligned values on most modern platforms (e.g. arm, x86) has no synchronization.
                //
                // Acquire memory barrier on success to ensure that the task reads & updates in the migration
                //   dont happen before the migrating steal has been confirmed/committed.
                const migrate = self.run_queue.len / 2;
                const new_head = head +% migrate;
                if (@cmpxchgWeak(
                    u8,
                    &self.runq_head,
                    head,
                    new_head,
                    .Acquire,
                    .Monotonic,
                )) |_| {
                    spinLoopHint();
                    continue;
                }

                // Prepend the migrated tasks to the existing task batch
                tasks.pushMany(blk: {
                    var overflowed = Batch{};
                    while (head != new_head) : (head +%= 1) {
                        const task = @atomicLoad(*Task, &self.run_queue[head % self.run_queue.len], .Unordered);
                        overflowed.push(task);
                    }
                    break :blk overflowed;
                });

                // then push the entire remaining batch to the overflow queue
                var runq_overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
                while (true) {
                    tasks.tail.next = runq_overflow;
                    const new_runq_overflow = tasks.head;

                    // if the overflow stack is empty, we can just store to it instead of cmpxchg.
                    // This is because we are the only producer thread.
                    if (runq_overflow == null) {
                        @atomicStore(?*Task, &self.runq_overflow, new_runq_overflow, .Release);
                        return;
                    }

                    runq_overflow = @cmpxchgWeak(
                        ?*Task,
                        &self.runq_overflow,
                        runq_overflow,
                        new_runq_overflow,
                        .Release,
                        .Monotonic,
                    ) orelse return;
                }
            }
        }

        /// Using the provided Thread, finds and dequeues a runnable task in the scheduler.
        fn pop(self: *Thread) ?*Task {
            var did_inject = false;
            const is_waking = self.worker_state == IS_WAKING;
            
            // look for a thread to run
            const task = self.poll(&did_inject) orelse return;

            // we should do a resume call if poll() added more tasks or if we're the waking thread.
            // if we're the waking thread, we need to either stop waking or wake another thread as the waking thread.
            // if we injected tasks into our run queue, then it means others may have failed to steal when we were injecting.
            if (is_waking or did_inject) {
                self.getScheduler().resumeThread(.{ .is_waking = is_waking });
                @atomicStore(u16, &self.worker_state, IS_RUNNING, .Unordered);
            }
            
            return task;
        }

        /// Poll for and dequeue a runnable Task from the Scheduler.
        /// Checks multiple layers of task run queues similar to a caching system. 
        fn poll(self: *Thread, did_inject: *bool) ?*Task {
            // TODO: check timers and maybe check IO if any

            // check our local queue first for tasks since this is fastest
            if (self.pollSelf(did_inject)) |task| {
                return task;
            }

            // our local queue is empty, check the scheduler for any new work
            const scheduler = self.getScheduler();
            if (self.pollScheduler(scheduler, did_inject)) |task| {
                return task;
            }
            
            // Iterate over the workers array from the scheduler starting at a random point.
            // This is just a tiny way to limit contention when stealing from other threads.
            const workers = scheduler.workers;
            var index = blk: {
                var x = self.xorshift;
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                self.xorshift = x;
                break :blk (x % workers.len);
            };

            var i: usize = workers.len;
            while (i != 0) : (i -= 1) {
                const worker = &workers[index];
                index = if (index == workers.len - 1) 0 else index + 1;
                
                // Try to steal from the Thread associated with this worker if it has any.
                // 
                // Acquire barrier in order to ensure we see valid memory from the threads.
                // note: There is a matching Release barrier on Thread creation which stores .running.
                const worker_ptr_value = @atomicLoad(usize, &worker.ptr, .Acquire);
                switch (Worker.Ptr.fromUsize(worker_ptr_value)) {
                    .idle, .spawning => {}, // skip idle/spawning workers as we cant steal anything from them
                    .shutdown => unreachable, // no worker should be shutdown while any worker thread is running
                    .running => |thread| {
                        if (thread == self)
                            continue; // we can't steal from ourselves.
                        if (self.pollOtherThread(thread, did_inject)) |task| {
                            return task;
                        } 
                    },
                }
            }

            // If we couldn't find any Tasks in ours and other Thread's run queues, then poll the Scheduler's run queue again.
            // This is the last ditch effort before giving up on search.
            if (self.pollScheduler(scheduler, did_inject)) |task| {
                return task;
            }

            // no tasks were actually found runnable on the system
            return null;
        }

        /// Poll for tasks that live in the local run queues of the Thread.
        fn pollSelf(self: *Thread, did_inject: *bool) ?*Task {
            // always check the "next" slot first for LIFO scheduling
            if (@atomicLoad(?*Task, &self.runq_next, .Monotonic) != null) {
                if (@atomicRmw(?*Task, &self.runq_next, .Xchg, null, .Acquire)) |task| {
                    return task;
                }
            }

            // check the local run_queue buffer for tasks
            const tail = self.runq_tail;
            var head = @atomicLoad(u8, &self.runq_head, .Monotonic);
            while (tail != head) {
                head = @cmpxchgWeak(
                    u8,
                    &self.runq_head,
                    head,
                    head +% 1,
                    .Acquire,
                    .Monotonic,
                ) orelse return @atomicLoad(*Task, &self.run_queue[head % self.run_queue.len], .Unordered);
            }

            // both the "next" slot and the local run_queue buffer are empty.
            // try to poll from and inject the runq_overflow stack into the run_queue buffer.
            var runq_overflow = @atomicLoad(?*Task, &self.runq_overflow, .Monotonic);
            while (runq_overflow) |top_task| {
                runq_overflow = @cmpxchgWeak(
                    ?*Task,
                    &self.runq_overflow,
                    runq_overflow,
                    null,
                    .Acquire,
                    .Monotonic,
                ) orelse {
                    self.inject(top_task.next, did_inject);
                    return top_task;
                };
            }

            // all the Thread local run queues are empty
            return null;
        }

        /// Poll for tasks on the given Thread's Scheduler.
        /// This touches resources generally shared by all threads.
        fn pollScheduler(
            noalias self: *Thread,
            noalias scheduler: *Scheduler,
            noalias did_inject: *bool,
        ) ?*Task {
            var run_queue = @atomicLoad(?*Task, &scheduler.run_queue, .Monotonic);
            while (run_queue) |top_task| {
                
                // steal the entire stack from the Scheduler's run_queue in one go.
                // This amortizes the cost of the cmpxchg as other threads will bail on the load above.
                // Acquire barrier in order for us to see any Task writes in the stack when we steal it.
                run_queue = @cmpxchgWeak(
                    ?*Task,
                    &scheduler.run_queue,
                    run_queue,
                    null,
                    .Acquire,
                    .Monotonic,
                ) orelse {
                    self.inject(top_task.next, did_inject);
                    return top_task;
                };
            }

            // the Scheduler's run_queue stack was empty
            return null;
        }

        /// Poll for tasks from another Thread and move them into our Thread.
        /// This acts as the main work-stealing algorithm.
        fn pollOtherThread(
            noalias self: *Thread,
            noalias target: *Thread,
            noalias did_inject: *bool,
        ) ?*Task {
            const tail = self.runq_tail;
            if (std.debug.runtime_safety) {
                const head = @atomicLoad(u8, &self.runq_head, .Monotonic);
                const size = tail -% head;
                if (size != 0) {
                    unreachable; // Thread stealing from another when local run queue isn't empty
                }
            }

            while (true) : (spinLoopHint()) {
                const target_head = @atomicLoad(u8, &target.runq_head, .Acquire);
                const target_tail = @atomicLoad(u8, &target.runq_tail, .Acquire);

                // check the size of the target's run queue, and retry if we loaded invalid head/tail combo
                const target_size = target_tail -% target_head;
                if (target_size > target.run_queue.len)
                    continue;

                // try to steal half of the tasks from the target's run queue
                var steal_size = target_size - (target_size / 2);
                if (steal_size == 0) {

                    // the target's run queue is empty, try to steal from its overflow stack
                    if (@atomicLoad(?*Task, &target.runq_overflow, .Monotonic) != null) {
                        if (@atomicRmw(?*Task, &target.runq_overflow, .Xchg, null, .Acquire)) |top_task| {
                            self.inject(top_task.next, did_inject);
                            return top_task;
                        }
                    }

                    // the target's run queue and overflow stack are empty, try to steal from its LIFO "next" slot.
                    // This is really a last resort as the "next" slot is generally meant to be run on the owning Thread.
                    if (@atomicLoad(?*Task, &target.runq_next, .Monotonic) != null) {
                        spinLoopHint();
                        if (@atomicRmw(?*Task, &target.runq_next, .Xchg, null, .Acquire)) |task| {
                            return task;
                        }
                    }

                    // the Thread is really empty
                    break;
                }

                // we will be returning the first task stolen
                const first_task = @atomicLoad(*Task, &target.run_queue[target_head % target.runq_queue.len], .Unordered);
                var new_target_head = target_head +% 1;
                steal_size -= 1;

                // prepare to racy read & steal (copy from theirs to ours) from the target's run queue buffer.
                // we cannot write to these tasks as we dont actually have ownership of the tasks were reading yet until the cmpxchg.
                var new_tail = tail;
                while (steal_size != 0) : (steal_size -= 1) {
                    const task = @atomicLoad(*Task, &target.run_queue[new_target_head % target.runq_queue.len], .Unordered);
                    new_target_head +%= 1;
                    @atomicStore(*Task, &self.run_queue[new_tail % self.runq_queue.len], task, .Unordered);
                    new_tail +%= 1;
                }

                // Try to commit that we stole the tasks from the target's run queue buffer.
                // Acquire barrier to ensure that when we succeed, we see valid Task writes and have ownership of the stolen Tasks.
                // There are matching Release barriers on the target_tail for when the tasks are put into the queue. 
                if (@cmpxchgWeak(
                    u8,
                    &target.runq_head,
                    target_head,
                    new_target_head,
                    .Acquire,
                    .Monotonic,
                )) |_| {
                    continue;
                }
                
                // If we copied tasks into our run queue buffer, then make them available to other threads.
                if (new_tail != tail) {
                    @atomicStore(u8, &self.runq_tail, new_tail, .Release);
                }

                did_inject.* = true;
                return first_task;
            }

            // There were no task found on the Thread
            return null;
        }

        /// Inject a stack of Tasks into the local run queue of this Thread.
        /// This must be called only from the producer OS thread of this Thread.
        /// This must also be called only if the run queue buffer is empty.
        fn inject(self: *Thread, runq_stack: ?*Task, did_inject: ?*bool) void {
            var runq = runq_stack orelse return;
            var tail = self.runq_tail;

            if (std.debug.runtime_safety) {
                const head = @atomicLoad(u8, &self.runq_head, .Monotonic);
                if (tail != head)
                    unreachable; // Thread inject when run_queue not empty
            }

            var i = self.run_queue.len;
            while (i != 0) : (i -= 1) {
                const task = runq orelse break;
                runq = task.next;
                @atomicStore(*Task, &self.run_queue[tail % self.run_queue.len], task, .Unordered);
                overflowed.push(task);;
                tail +%= 1;
                break :blk overflowed;
            }

            @atomicStore(u8, &self.runq_tail, tail, .Release);
            if (did_inject) |did_inject_ptr| {
                did_inject_ptr.* = true;
            }

            if (runq) |remaining| {
                if (std.debug.runtime_safety) {
                    if (@atomicLoad(?*Task, &self.runq_overflow, .Monotonic) != null)
                        unreachable; // Thread inject when runq_overflow not empty
                }
                @atomicStore(?*Task, &self.runq_overflow, remaining, .Release);
            }
        }
    };
};