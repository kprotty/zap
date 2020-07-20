const std = @import("std");

const CACHE_LINE =
    if (std.builtin.arch == .x86_64) 64 * 2
    else 64;

pub const Scheduler = extern struct {
    pub const Options = struct {
        max_core_threads: usize = std.math.maxInt(usize),
        max_blocking_threads: usize = 64,
    };

    pub const RunAsyncError = error{
        DeadLocked,  
    } || RunError;

    pub fn runAsync(
        options: Options,
        comptime entryFn: var,
        args: var,
    ) RunAsyncError!@TypeOf(entryFn).ReturnType {
        const ReturnType = @TypeOf(entryFn).ReturnType;
        const Wrapper = struct {
            fn entry(
                comptime func: var,
                func_args: var,
                task_ptr: *Task,
                result_ptr: *?ReturnType,
            ) void {
                task_ptr.* = Task.init(@frame());
                suspend;
                const result = @call(.{}, func, func_args);
                result_ptr.* = result;
            }
        };

        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.entry(entryFn, args, &task, &result);
        try run(options, &task.runnable);

        return result orelse error.DeadLocked;
    }

    active_threads: usize align(CACHE_LINE),
    blocking_pool: Thread.Pool,
    core_pool: Thread.Pool,

    pub const RunError = error {
        OutOfMemory,
    };

    pub fn run(options: Options, runnable: *Runnable) RunError!void {
        const system_threads = if (std.builtin.single_threaded) 1 else std.Thread.cpuCount() catch 1;
        const core_threads = std.math.min(system_threads, std.math.max(1, options.max_core_threads));
        const blocking_threads = std.math.min(1024, std.math.max(1, options.max_blocking_threads));

        const allocator = if (std.builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;
        const slots = allocator.alloc(Thread.Slot, core_threads + blocking_threads) catch return error.OutOfMemory;
        defer allocator.free(slots);

        var self = Scheduler{
            .active_threads = 0,
            .core_pool = undefined,
            .blocking_pool = undefined,
        };
        self.core_pool.init(slots[0..core_threads], false, &self);
        self.blocking_pool.init(slots[core_threads..], true, &self);
        
        self.core_pool.run_queue.push(Runnable.Batch.from(runnable));
        self.core_pool.resumeThread();

        const active_threads = @atomicLoad(usize, &self.active_threads, .SeqCst);
        if (active_threads != 0)
            std.debug.panic("Scheduler shutting down with {} active_threads", .{active_threads});
        self.core_pool.deinit();
        self.blocking_pool.deinit();
    }
};

pub const Thread = struct {
    const Slot = struct {
        next: usize,
        data: usize,
    };

    const IdleQueue = switch (std.builtin.arch) {
        .i386, .x86_64 => extern struct {
            value: usize align(@alignOf(DoubleWord)),
            aba_tag: usize = 0,

            const DoubleWord = @Type(std.builtin.TypeInfo{
                .Int = std.builtin.TypeInfo.Int{
                    .is_signed = false,
                    .bits = @typeInfo(usize).Int.bits * 2,
                },
            });

            fn load(
                self: *IdleQueue,
                comptime order: std.builtin.AtomicOrder,
            ) IdleQueue {
                return IdleQueue{
                    .value = @atomicLoad(usize, &self.value, order),
                    .aba_tag = @atomicLoad(usize, &self.aba_tag, .Unordered),
                };
            }

            fn compareExchange(
                self: *IdleQueue,
                compare: IdleQueue,
                exchange: usize,
                comptime success: std.builtin.AtomicOrder,
                comptime failure: std.builtin.AtomicOrder,
            ) ?IdleQueue {
                const double_word = @cmpxchgWeak(
                    DoubleWord,
                    @ptrCast(*DoubleWord, self),
                    @bitCast(DoubleWord, compare),
                    @bitCast(DoubleWord, IdleQueue{
                        .value = exchange,
                        .aba_tag = compare.aba_tag +% 1,
                    }),
                    success,
                    failure,
                ) orelse return null;
                return @bitCast(IdleQueue, double_word);
            }
        },
        else => extern struct {
            value: usize,

            fn load(
                self: *IdleQueue,
                comptime order: std.builtin.AtomicOrder,
            ) IdleQueue {
                const value = @atomicLoad(usize, &self.value, order);
                return IdleQueue{ .value = value };
            }

            fn compareExchange(
                self: *IdleQueue,
                compare: IdleQueue,
                exchange: usize,
                comptime success: std.builtin.AtomicOrder,
                comptime failure: std.builtin.AtomicOrder,
            ) ?IdleQueue {
                const value = @cmpxchgWeak(
                    usize,
                    &self.value,
                    compare.value,
                    exchange,
                    success,
                    failure,
                ) orelse return null;
                return IdleQueue{ .value = value };
            }
        },
    };

    const Pool = extern struct {
        idle_queue: IdleQueue align(CACHE_LINE),
        run_queue: GloablQueue,
        slots_ptr: [*]Slot,
        slots_len: usize,
        scheduler_ptr: usize,

        const IDLE_EMPTY: usize = 0;
        const IDLE_STOPPED: usize = 1;
        const IDLE_NOTIFIED: usize = 2;

        fn init(
            self: *Pool,
            slots: []Slot,
            is_blocking: bool,
            scheduler: *Scheduler,
        ) void {
            self.* = Pool{
                .idle_queue = IdleQueue{ .value = IDLE_EMPTY },
                .run_queue = undefined,
                .slots_ptr = slots.ptr,
                .slots_len = slots.len,
                .scheduler_ptr = @ptrToInt(scheduler) | @boolToInt(is_blocking),
            };

            self.run_queue.init();
            for (self.getSlots()) |*slot| {
                defer self.idle_queue = IdleQueue{ .value = @ptrToInt(slot) };
                slot.* = Slot{
                    .next = self.idle_queue.value,
                    .data = 0x0,
                };
            }
        }

        fn deinit(self: *Pool) void {
            defer self.* = undefined;
            self.run_queue.deinit();

            for (self.getSlots()) |*slot| {
                if (slot.data == 0)
                    continue;
                if (slot.data & 1 == 0)
                    std.debug.panic("Thread without handle set on pool deinit", .{});
                const thread_handle = @intToPtr(*std.Thread, slot.data & ~@as(usize, 1));
                thread_handle.wait();
            }            
        }

        fn isBlockingPool(self: Pool) bool {
            return self.scheduler_ptr & 1 != 0;
        }

        fn getSlots(self: Pool) []Slot {
            return self.slots_ptr[0..self.slots_len];
        }

        fn getScheduler(self: Pool) *Scheduler {
            return @intToPtr(*Scheduler, self.scheduler_ptr & ~@as(usize, 1));
        }

        fn resumeThread(self: *Pool) void {
            if (std.builtin.single_threaded)
                return;

            var idle_queue = self.idle_queue.load(.Acquire);
            while (true) {
                switch (idle_queue.value) {
                    IDLE_STOPPED => {
                        std.debug.panic("Tried to resume a thread when pool is stopped", .{});
                    },
                    IDLE_NOTIFIED => {
                        return;
                    },
                    IDLE_EMPTY => {
                        idle_queue = self.idle_queue.compareExchange(
                            idle_queue,
                            IDLE_NOTIFIED,
                            .Acquire,
                            .Acquire,
                        ) orelse return;
                    },
                    else => |slot_ptr| {
                        const slot = @intToPtr(*Slot, slot_ptr);
                        idle_queue = self.idle_queue.compareExchange(
                            idle_queue,
                            slot.next,
                            .Acquire,
                            .Acquire,
                        ) orelse return self.resumeSlot(slot);
                    },
                }
            }
        }

        fn resumeSlot(
            noalias self: *Pool,
            noalias slot: *Slot,
        ) void {
            const scheduler = self.getScheduler();
            const active_threads = @atomicRmw(usize, &scheduler.active_threads, .Add, 1, .Acquire);
            const is_main_thread = active_threads == 0;

            if (@intToPtr(?*Thread, slot.data)) |thread| {
                std.debug.assert(!is_main_thread);
                thread.event.set();
                return;
            }

            slot.data = 0;
            slot.next = @ptrToInt(self);
            if (is_main_thread) {
                Thread.run(slot);
                return;
            }

            if (std.Thread.spawn(slot, Thread.run)) |thread_handle| {
                if (@cmpxchgStrong(
                    usize,
                    &slot.data,
                    0,
                    @ptrToInt(thread_handle) | 1,
                    .AcqRel,
                    .Acquire,
                )) |thread_ptr| {
                    const thread = @intToPtr(*Thread, thread_ptr);
                    thread.handle = thread_handle;
                    @fence(.Release);
                }
                return;
            } else |err| {
                _ = @atomicRmw(usize, &scheduler.active_threads, .Sub, 1, .Release);
            }

            slot.data = 0;
            var idle_queue = self.idle_queue.load(.Monotonic);
            while (true) {
                if (idle_queue.value == IDLE_STOPPED)
                    std.debug.panic("Tried to re-queue slot while pool was stopping", .{});

                slot.next = switch (idle_queue.value) {
                    IDLE_NOTIFIED => IDLE_EMPTY,
                    else => |slot_ptr| slot_ptr,
                };

                idle_queue = self.idle_queue.compareExchange(
                    idle_queue,
                    @ptrToInt(slot),
                    .Release,
                    .Monotonic,
                ) orelse return;
            }
        }

        fn suspendThread(
            noalias self: *Pool,
            noalias thread: *Thread,
        ) void {
            const slot = thread.slot;
            std.debug.assert(slot.data == @ptrToInt(thread));
            var idle_queue = self.idle_queue.load(.Monotonic);

            while (true) {
                switch (idle_queue.value) {
                    IDLE_STOPPED => {
                        std.debug.panic("Tried to suspend thread while stopped", .{});
                    },
                    IDLE_NOTIFIED => {
                        idle_queue = self.idle_queue.compareExchange(
                            idle_queue,
                            IDLE_EMPTY,
                            .Monotonic,
                            .Monotonic,
                        ) orelse return;
                    },
                    else => |slot_ptr| {
                        slot.next = slot_ptr;
                        idle_queue = self.idle_queue.compareExchange(
                            idle_queue,
                            @ptrToInt(slot),
                            .Release,
                            .Monotonic,
                        ) orelse break;
                    },
                }
            }

            const scheduler = self.getScheduler();
            const active_threads = @atomicRmw(usize, &scheduler.active_threads, .Sub, 1, .Release);
            if (active_threads == 1) {
                scheduler.core_pool.shutdown();
                scheduler.blocking_pool.shutdown();
            }

            thread.event.wait();
            thread.event.reset();
        }

        fn shutdown(self: *Pool) void {
            var idle_queue_state = @atomicRmw(
                usize,
                &self.idle_queue.value,
                .Xchg,
                IDLE_STOPPED,
                .Acquire,
            );

            var num_slots: usize = 0;
            var idle_threads: ?*Thread = null;
            while (true) {
                switch (idle_queue_state) {
                    IDLE_STOPPED => {
                        std.debug.panic("Pool was stopped more than once on shutdown", .{});
                    },
                    IDLE_NOTIFIED => {
                        std.debug.panic("Pool with empty idle queue on shutdown", .{});
                    },
                    else => |slot_ptr| {
                        const slot = @intToPtr(?*Slot, slot_ptr) orelse break;
                        idle_queue_state = slot.next;
                        num_slots += 1;

                        const thread = @intToPtr(?*Thread, slot.data) orelse continue;
                        thread.next = idle_threads;
                        idle_threads = thread;

                        @fence(.Acquire);
                        if (thread.handle) |thread_handle| {
                            slot.data = @ptrToInt(thread_handle) | 1;
                        } else {
                            slot.data = 0;
                        }
                    },
                }
            }

            const expected_slots = self.getSlots().len;
            if (num_slots != expected_slots)
                std.debug.panic("Pool.shutdown() found {} slots expected {}\n", .{num_slots, expected_slots});

            while (idle_threads) |idle_thread| {
                const thread = idle_thread;
                idle_threads = thread.next;
                thread.event.set();
            }
        }
    };

    lifo_slot: ?*Runnable align(CACHE_LINE),
    run_queue: LocalQueue,
    event: std.ResetEvent,
    handle: ?*std.Thread,
    pool: *Pool,
    slot: *Slot,
    next: ?*Thread,
    
    pub threadlocal var current: ?*Thread = null;

    fn run(slot: *Slot) void {
        const pool = @intToPtr(*Pool, slot.next);
        var self = Thread{
            .lifo_slot = null,
            .run_queue = LocalQueue.init(),
            .event = std.ResetEvent.init(),
            .handle = null,
            .pool = pool,
            .slot = slot,
            .next = null,
        };

        Thread.current = &self;
        defer {
            self.event.deinit();
            self.run_queue.deinit();
            Thread.current = null;
        }

        const data = @atomicRmw(usize, &slot.data, .Xchg, @ptrToInt(&self), .AcqRel);
        if (@intToPtr(?*std.Thread, data & ~@as(usize, 1))) |thread_handle| {
            self.handle = thread_handle;
            @fence(.Release);
        }

        var iteration: usize = 0;
        var rng_state = @truncate(u32, @ptrToInt(&self) ^ @ptrToInt(pool));
        while (slot.data == @ptrToInt(&self)) {
            
            const runnable = self.poll(pool, iteration, &rng_state) orelse {
                pool.suspendThread(&self);
                continue;
            };

            iteration +%= 1;
            (runnable.callback)(runnable);
        }
    }

    fn poll(
        noalias self: *Thread,
        noalias pool: *Pool,
        iteration: usize,
        rng_state: *u32,
    ) ?*Runnable {
        if (iteration % 61 == 0) {
            if (self.run_queue.tryStealFromGlobal(&pool.run_queue)) |runnable| {
                pool.resumeThread();
                return runnable;
            }
        }

        if (@atomicLoad(?*Runnable, &self.lifo_slot, .Monotonic) != null) {
            if (@atomicRmw(?*Runnable, &self.lifo_slot, .Xchg, null, .Acquire)) |runnable| {
                return runnable;
            }
        }

        if (self.run_queue.popFront()) |runnable| {
            return runnable;
        }

        var steal_attempts: u3 = 4;
        const slots = pool.getSlots();
        while (steal_attempts != 0) : (steal_attempts -= 1) {
            
            if (self.run_queue.tryStealFromGlobal(&pool.run_queue)) |runnable| {
                pool.resumeThread();
                return runnable;
            }

            var rng = rng_state.*;
            rng ^= rng << 13;
            rng ^= rng >> 17;
            rng ^= rng << 5;
            rng_state.* = rng;

            var slot_iter = slots.len;
            var index: usize = rng % slots.len;
            while (slot_iter != 0) : (slot_iter -= 1) {
                defer {
                    index +%= 1;
                    if (index >= slots.len)
                        index = 0;
                }

                const data = @atomicLoad(usize, &slots[index].data, .Acquire);
                if (data & 1 != 0)
                    continue;

                const thread = @intToPtr(?*Thread, data) orelse continue;
                if (thread == self)
                    continue;

                if (self.run_queue.tryStealFromLocal(&thread.run_queue)) |runnable| {
                    pool.resumeThread();
                    return runnable;
                }

                if (steal_attempts <= 2) {
                    if (@atomicLoad(?*Runnable, &thread.lifo_slot, .Monotonic) != null) {
                        if (@atomicRmw(?*Runnable, &thread.lifo_slot, .Xchg, null, .Acquire)) |runnable| {
                            return runnable;
                        }
                    }
                }
            }
        }

        return null;
    }

    const GloablQueue = extern struct {
        is_locked: bool align(CACHE_LINE),
        head: *Runnable align(CACHE_LINE),
        tail: *Runnable,
        stub_next: ?*Runnable,

        fn init(self: *GloablQueue) void {
            self.is_locked = false;
            self.stub_next = null;
            const stub = @fieldParentPtr(Runnable, "next", &self.stub_next);
            self.head = stub;
            self.tail = stub;
        }

        fn deinit(self: *GloablQueue) void {
            if (!self.isEmpty())
                std.debug.panic("Non-empty GlobalQueue on deinit()", .{});
            self.* = undefined;
        }


        fn isEmpty(self: *const GloablQueue) bool {
            const stub = @fieldParentPtr(Runnable, "next", &self.stub_next);
            const head = @atomicLoad(*Runnable, &self.head, .Monotonic);
            return head == stub;
        }

        fn push(self: *GloablQueue, list: Runnable.Batch) void {
            const head = list.head orelse return;
            const tail = list.tail orelse return;

            tail.next = null;
            const prev = @atomicRmw(*Runnable, &self.head, .Xchg, tail, .AcqRel);
            @atomicStore(?*Runnable, &prev.next, head, .Release);
        }

        fn pop(self: *GloablQueue) ?*Runnable {
            var tail = self.tail;
            var next = @atomicLoad(?*Runnable, &tail.next, .Acquire);

            const stub = @fieldParentPtr(Runnable, "next", &self.stub_next);
            if (tail == stub) {
                tail = next orelse return null;
                self.tail = tail;
                next = @atomicLoad(?*Runnable, &tail.next, .Acquire);
            }

            if (next) |next_runnable| {
                self.tail = next_runnable;
                return tail;
            }

            const head = @atomicLoad(?*Runnable, &self.head, .Monotonic);
            if (head != tail)
                return null;

            self.push(Runnable.Batch.from(stub));
            self.tail = @atomicLoad(?*Runnable, &tail.next, .Acquire) orelse return null;
            return tail;
        }
    };

    const LocalQueue = extern struct {
        head: usize align(CACHE_LINE),
        tail: usize align(CACHE_LINE),
        buffer: [BUFFER_SIZE]*Runnable,

        const BUFFER_SIZE = 256;

        fn init() LocalQueue {
            return LocalQueue{
                .head = 0,
                .tail = 0,
                .buffer = undefined,
            };
        }

        fn deinit(self: *LocalQueue) void {
            if (!self.isEmpty())
                std.debug.panic("Non-empty LocalQueue on deinit()", .{});
            self.* = undefined;
        }

        fn isEmpty(self: *const LocalQueue) bool {
            const head = @atomicLoad(usize, &self.head, .Monotonic);
            const tail = @atomicLoad(usize, &self.tail, .Monotonic);
            return tail == head;
        }

        fn pushBack(
            noalias self: *LocalQueue,
            noalias runnable: *Runnable,
            noalias overflow_queue: *GloablQueue,
        ) void {
            const tail = self.tail;
            var head = @atomicLoad(usize, &self.head, .Monotonic);

            while (true) {
                if (tail -% head < BUFFER_SIZE) {
                    self.buffer[tail % BUFFER_SIZE] = runnable;
                    @atomicStore(usize, &self.tail, tail +% 1, .Release);
                    return;
                }

                var migrate: usize = BUFFER_SIZE / 2;
                if (@cmpxchgWeak(
                    usize,
                    &self.head,
                    head,
                    head +% migrate,
                    .Monotonic,
                    .Monotonic,
                )) |new_head| {
                    head = new_head;
                    continue;
                }

                var overflow_batch = Runnable.Batch{};
                while (migrate != 0) : (migrate -= 1) {
                    const migrated_runnable = self.buffer[head % BUFFER_SIZE];
                    overflow_batch.push(migrated_runnable);
                    head +%= 1;
                }

                overflow_batch.push(runnable);
                overflow_queue.push(overflow_batch);
                return;
            }
        }

        fn popFront(self: *LocalQueue) ?*Runnable {
            const tail = self.tail;
            var head = @atomicLoad(usize, &self.head, .Monotonic);

            while (true) {
                if (tail == head)
                    return null;
                head = @cmpxchgWeak(
                    usize,
                    &self.head,
                    head,
                    head +% 1,
                    .Monotonic,
                    .Monotonic,
                ) orelse return self.buffer[head % BUFFER_SIZE];
            }
        }

        fn tryStealFromLocal(
            noalias self: *LocalQueue,
            noalias target: *LocalQueue,
        ) ?*Runnable {
            const tail = self.tail;
            var target_head = @atomicLoad(usize, &target.head, .Acquire);
            while (true) {
                var target_tail = @atomicLoad(usize, &target.tail, .Acquire);

                var migrate = target_tail -% target_head;
                migrate = migrate - (migrate / 2);
                if (migrate == 0)
                    return null;

                var new_target_head = target_head;
                const runnable = target.buffer[new_target_head % BUFFER_SIZE];
                new_target_head +%= 1;
                migrate -%= 1;

                var new_tail = tail;
                while (migrate != 0) : (migrate -= 1) {
                    const migrated_runnable = target.buffer[new_target_head % BUFFER_SIZE];
                    new_target_head +%= 1;
                    self.buffer[new_tail % BUFFER_SIZE] = migrated_runnable;
                    new_tail +%= 1;
                }

                if (@cmpxchgWeak(
                    usize,
                    &target.head,
                    target_head,
                    new_target_head,
                    .AcqRel,
                    .Acquire,
                )) |updated_target_head| {
                    target_head = updated_target_head;
                    continue;
                }

                if (tail != new_tail)
                    @atomicStore(usize, &self.tail, new_tail, .Release);
                return runnable;
            }
        }

        fn tryStealFromGlobal(
            noalias self: *LocalQueue,
            noalias target: *GloablQueue,
        ) ?*Runnable {
            if (target.isEmpty())
                return null;

            if (@atomicLoad(bool, &target.is_locked, .Monotonic))
                return null;
            if (@atomicRmw(bool, &target.is_locked, .Xchg, true, .Acquire))
                return null;
            defer @atomicStore(bool, &target.is_locked, false, .Release);

            const runnable = target.pop() orelse return null;

            const head = @atomicLoad(usize, &self.head, .Monotonic);
            const tail = self.tail;
            var new_tail = tail;
            var migrate = BUFFER_SIZE - (tail -% head);

            while (migrate != 0) : (migrate -= 1) {
                const migrated_runnable = target.pop() orelse break;
                self.buffer[new_tail % BUFFER_SIZE] = migrated_runnable;
                new_tail +%= 1;
            }

            if (tail != new_tail)
                @atomicStore(usize, &self.tail, new_tail, .Release);
            return runnable;
        }
    };
};

pub const Runnable = struct {
    next: ?*Runnable,
    callback: Callback,

    pub const Callback = fn(*Runnable) callconv(.C) void;

    pub fn init(callback: Callback) Runnable {
        return Runnable{
            .next = undefined,
            .callback = callback,
        };
    }

    pub fn schedule(self: *Runnable) void {
        Batch.from(self).schedule();
    }

    pub const Batch = struct {
        head: ?*Runnable = null,
        tail: ?*Runnable = null,
        len: usize = 0,

        pub fn from(runnable: *Runnable) Batch {
            var self = Batch{};
            self.push(runnable);
            return self;
        }

        pub fn push(
            noalias self: *Batch,
            noalias runnable: *Runnable,
        ) void {
            runnable.next = null;
            if (self.head == null)
                self.head = runnable;
            if (self.tail) |tail|
                tail.next = runnable;
            self.tail = runnable;
            self.len += 1;
        }

        pub fn pop(self: *Batch) ?*Runnable {
            const runnable = self.head orelse return null;
            self.head = runnable.next;
            if (self.head == null)
                self.tail = runnable;
            self.len -= 1;
            return runnable;
        }

        pub fn schedule(self: Batch) void {
            if (self.len == 0)
                return;

            const thread = Thread.current orelse {
                std.debug.panic("Trying to schedule a task when not running in a scheduler", .{});
            };

            const pool = thread.pool;
            if (pool.isBlockingPool()) {
                std.debug.panic("Trying to schedule a normal task onto blocking pool", .{});
            }

            if (self.len == 1) {
                var runnable: ?*Runnable = self.head.?;
                runnable = @atomicRmw(?*Runnable, &thread.lifo_slot, .Xchg, runnable, .AcqRel);
                if (runnable) |next_runnable| {
                    thread.run_queue.pushBack(next_runnable, &pool.run_queue);
                }
            } else {
                pool.run_queue.push(self);
            }
            pool.resumeThread();
        }
    };
};

pub const Task = struct {
    runnable: Runnable,
    frame: anyframe,

    pub fn init(frame: anyframe) Task {
        return Task{
            .runnable = Runnable.init(@"resume"),
            .frame = frame,
        };
    }

    fn @"resume"(runnable: *Runnable) callconv(.C) void {
        const task = @fieldParentPtr(Task, "runnable", runnable);
        resume task.frame;
    }

    pub fn yield() void {
        var task = Task.init(@frame());
        suspend {
            Task.schedule(&task);
        }
    }

    pub fn schedule(task: *Task) void {
        Runnable.Batch.from(&task.runnable).schedule();
    }
};

