const std = @import("std");

const CACHE_LINE = switch (std.builtin.arch) {
    .x86_64 => 64 * 2,
    else => 64,
};

pub const Scheduler = extern struct {
    pub const Config = extern struct {
        max_workers: usize = std.math.maxInt(usize),
    };

    const IDLE_EMPTY = 0;
    const IDLE_NOTIFIED = 1;
    const IDLE_SHUTDOWN = 2;
    const IDLE_WAKING = 4;

    active_threads: usize,
    idle_queue: AtomicUsize align(CACHE_LINE),
    run_queue: GlobalQueue,
    workers_ptr: [*]Worker align(CACHE_LINE),
    workers_len: usize,

    pub fn runAsync(config: Config, comptime func: var, args: var) !@TypeOf(func).ReturnType {
        const ReturnType = @TypeOf(func).ReturnType;
        const Wrapper = struct {
            fn call(func_args: var, task: *Task, result: *?ReturnType) void {
                suspend {
                    task.* = Task.init(@frame());
                }
                const value = @call(.{}, func, func_args);
                result.* = value;
            }
        };

        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.call(args, &task, &result);

        try run(config, &task.runnable);

        return result orelse error.DeadLocked;
    }

    pub fn run(config: Config, runnable: *Runnable) !void {
        var num_workers = if (std.builtin.single_threaded) 1 else (std.Thread.cpuCount() catch 1);
        num_workers = std.math.max(1, std.math.min(config.max_workers, num_workers));

        if (num_workers <= 8) {
            var workers: [8]Worker = undefined;
            return runUsing(workers[0..num_workers], runnable);
        }

        const allocator = if (std.builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;
        const workers = try allocator.alloc(Worker, num_workers);
        defer allocator.free(workers);
        return runUsing(workers, runnable);
    }

    fn runUsing(workers: []Worker, runnable: *Runnable) !void {
        var self = Scheduler{
            .active_threads = 0,
            .idle_queue = AtomicUsize{ .value = IDLE_EMPTY },
            .run_queue = undefined,
            .workers_ptr = workers.ptr,
            .workers_len = workers.len,
        };

        self.run_queue.init();
        for (workers) |*worker| {
            defer self.idle_queue.value = @ptrToInt(worker);
            worker.* = Worker{
                .next = self.idle_queue.value,
                .thread = null,
                .handle = null,
            };
        }

        defer {
            for (workers) |*worker| {
                const handle_ptr = @atomicLoad(?*std.Thread, &worker.handle, .Acquire);
                const thread_handle = handle_ptr orelse continue;
                thread_handle.wait();
            }

            const active_threads = @atomicLoad(usize, &self.active_threads, .Monotonic);
            if (active_threads != 0) {
                std.debug.panic("Scheduler exiting with {} active_threads", .{active_threads});
            }

            const idle_queue = self.idle_queue.load(.Monotonic).value;
            if (idle_queue != IDLE_SHUTDOWN) {
                std.debug.panic("Scheduler exiting when idle_queue is not shutdown", .{});
            }

            self.run_queue.deinit();
        }

        self.run_queue.push(Runnable.Batch.from(runnable));
        self.resumeThreadWhen(.{ .is_main_thread = true });        
    }

    fn resumeThread(self: *Scheduler) void {
        self.resumeThreadWhen(.{});
    }

    fn stopWaking(self: *Scheduler) void {
        self.resumeThreadWhen(.{ .was_waking = true });
    }

    const ResumeOptions = struct {
        was_waking: bool = false,
        is_main_thread: bool = false,
    };

    fn resumeThreadWhen(
        self: *Scheduler,
        resume_options: ResumeOptions,
    ) void {
        const was_waking = resume_options.was_waking;
        var idle_queue = self.idle_queue.load(.Acquire);
        while (true) {
            if (idle_queue.value == IDLE_SHUTDOWN)
                std.debug.panic("Scheduler.resumeThread() when shutdown", .{});

            if (!was_waking) {
                if (idle_queue.value == IDLE_NOTIFIED or idle_queue.value & IDLE_WAKING != 0)
                    return;
            }
            
            const worker_ptr = @intToPtr(?*Worker, idle_queue.value & ~@as(usize, IDLE_WAKING | IDLE_NOTIFIED));
            var next_value: usize = undefined;
            if (worker_ptr) |worker| {
                next_value = @atomicLoad(usize, &worker.next, .Unordered) | IDLE_WAKING;
            } else {
                next_value = IDLE_NOTIFIED;
            }

            if (self.idle_queue.compareExchangeWeak(
                idle_queue,
                next_value,
                .AcqRel,
                .Acquire,
            )) |new_idle_queue| {
                idle_queue = new_idle_queue;
                continue;
            }

            const worker = worker_ptr orelse return;
            _ = @atomicRmw(usize, &self.active_threads, .Add, 1, .SeqCst);

            worker.next = @ptrToInt(self);
            if (resume_options.is_main_thread) {
                Thread.run(worker);
                return;
            }

            if (worker.thread) |thread| {
                if (thread.state != .suspended)
                    std.debug.panic("resumeThread() with thread state {}", .{thread.state});
                thread.state = .waking;
                thread.event.set();
                return;
            }

            if (std.Thread.spawn(worker, Thread.run)) |handle| {
                @atomicStore(?*std.Thread, &worker.handle, handle, .Release);
                return;
            } else |err| {
                _ = @atomicRmw(usize, &self.active_threads, .Sub, 1, .SeqCst);
            }

            idle_queue = self.idle_queue.load(.SeqCst);
            while (true) {
                worker.next = idle_queue.value & ~@as(usize, IDLE_WAKING);
                if (worker.next == IDLE_NOTIFIED)
                    worker.next = IDLE_EMPTY;
                idle_queue = self.idle_queue.compareExchangeWeak(
                    idle_queue,
                    @ptrToInt(worker) & ~@as(usize, IDLE_WAKING),
                    .SeqCst,
                    .SeqCst,
                ) orelse return;
            }
        }
    }

    fn suspendThread(
        noalias self: *Scheduler,
        noalias worker: *Worker,
        noalias thread: *Thread,
    ) void {
        const was_waking = switch (thread.state) {
            .running => false,
            .waking => true,
            .suspended => {
                std.debug.panic("suspendThread() when thread already suspended", .{});
            },
            .shutdown => {
                std.debug.panic("suspendThread() when thread is shutdown", .{});
            },
        };

        var idle_queue = self.idle_queue.load(.Monotonic);
        while (true) {
            if (idle_queue.value == IDLE_SHUTDOWN)
                std.debug.panic("Scheduler.suspendThread() when shutdown", .{});

            var next_value: usize = undefined;
            if (idle_queue.value == IDLE_NOTIFIED) {
                next_value = IDLE_EMPTY;
            } else {
                next_value = @ptrToInt(worker) | (idle_queue.value & IDLE_WAKING);
                if (was_waking)
                    next_value &= ~@as(usize, IDLE_WAKING);
                thread.state = .suspended;
                const next_worker = idle_queue.value & ~@as(usize, IDLE_WAKING);
                @atomicStore(usize, &worker.next, next_worker, .Unordered);
            }

            if (self.idle_queue.compareExchangeWeak(
                idle_queue,
                next_value,
                .Release,
                .Monotonic,
            )) |new_idle_queue| {
                idle_queue = new_idle_queue;
                continue;
            }

            if (idle_queue.value == IDLE_NOTIFIED) {
                thread.state = if (was_waking) .waking else .running;
                thread.event.set();
                return;
            }

            const active_threads = @atomicRmw(usize, &self.active_threads, .Sub, 1, .SeqCst);
            if (active_threads == 1) {
                
                // Bug on ReleaseFast where it somehow leaves is_polling set ??
                // See: LocalQueue.tryStealFromGlobal() to see how is_polling is used.
                if (!std.debug.runtime_safety and @atomicLoad(bool, &self.run_queue.is_polling, .SeqCst)) {
                    @atomicStore(bool, &self.run_queue.is_polling, false, .SeqCst);
                    self.resumeThread();
                } else {
                    self.shutdown();
                }
            }

            return;
        }
    }

    fn shutdown(self: *Scheduler) void {
        var idle_queue = @atomicRmw(
            usize,
            &self.idle_queue.value,
            .Xchg,
            IDLE_SHUTDOWN,
            .SeqCst,
        );

        var s :
        
        var num_workers: usize = 0;
        while (true) {
            const worker = @intToPtr(?*Worker, idle_queue) orelse break;
            idle_queue = worker.next;
            num_workers += 1;
            
            const thread = worker.thread orelse continue;
            thread.state = .shutdown;
            thread.event.set();
        }
        
        if (num_workers != self.workers_len)
            std.debug.panic("Scheduler.shutdown() only shutdown {}/{} workers", .{num_workers, self.workers_len});
    }
};

const Worker = extern struct {
    next: usize align(8),
    thread: ?*Thread,
    handle: ?*std.Thread,
};

const Thread = struct {
    threadlocal var current: ?*Thread = null;

    const State = enum {
        running,
        waking,
        suspended,
        shutdown,
    };

    state: State,
    event: std.ResetEvent,
    run_queue: LocalQueue,
    scheduler: *Scheduler,

    fn run(worker: *Worker) void {
        const scheduler = @intToPtr(*Scheduler, worker.next);
        var self = Thread{
            .state = .waking,
            .event = std.ResetEvent.init(),
            .run_queue = LocalQueue.init(),
            .scheduler = scheduler,
        };

        defer {
            self.event.deinit();
            self.run_queue.deinit();
            if (self.state != .shutdown)
                std.debug.panic("Thread.exit() while state = {}", .{self.state});
        }

        Thread.current = &self;
        @atomicStore(?*Thread, &worker.thread, &self, .Release);

        var tick: u8 = 0;
        var rng = @truncate(u32, @ptrToInt(&self));
        while (true) {

            if (self.poll(scheduler, &rng, tick)) |runnable| {
                if (self.state == .waking)
                    scheduler.stopWaking();
                tick +%= 1;
                self.state = .running;
                (runnable.callback)(runnable);
                continue;
            }

            scheduler.suspendThread(worker, &self);
            self.event.wait();
            self.event.reset();

            switch (self.state) {
                .shutdown => break,
                .waking, .running => {},
                .suspended => {
                    std.debug.panic("Thread.afterSuspend() still suspended", .{});
                },
            }
        }
    }

    fn schedule(self: *Thread, batch: Runnable.Batch, store_next: bool) void {
        const scheduler = self.scheduler;

        switch (batch.len) {
            0 => return,
            1 => self.run_queue.pushWithOverflow(
                &scheduler.run_queue,
                batch.head.?,
                store_next,
            ),
            else => scheduler.run_queue.push(batch),
        }
        
        scheduler.resumeThread();
    }

    fn poll(
        noalias self: *Thread,
        noalias scheduler: *Scheduler,
        noalias rng_ptr: *u32,
        tick: u8, 
    ) ?*Runnable {
        if (tick % 61 == 0) {
            if (self.run_queue.tryStealFromGlobal(&scheduler.run_queue)) |runnable| {
                if (self.state != .waking)
                    scheduler.resumeThread();
                return runnable;
            }
        }

        if (self.run_queue.tryPop()) |runnable| {
            return runnable;
        }

        const workers = scheduler.workers_ptr[0..scheduler.workers_len];
        var steal_attempts: u3 = 4;
        while (steal_attempts != 0) : (steal_attempts -= 1) {

            if (self.run_queue.tryStealFromGlobal(&scheduler.run_queue)) |runnable| {
                if (self.state != .waking)
                    scheduler.resumeThread();
                return runnable;
            }

            const steal_next = steal_attempts < 2;

            var worker_index = blk: {
                var rng = rng_ptr.*;
                rng ^= rng << 13;
                rng ^= rng >> 17;
                rng ^= rng << 5;
                rng_ptr.* = rng;
                break :blk (rng % workers.len);
            };

            var worker_iter = workers.len;
            while (worker_iter != 0) : (worker_iter -= 1) {
                const worker_ptr = &workers[worker_index];
                worker_index += 1;
                if (worker_index == workers.len)
                    worker_index = 0;

                const thread_ptr = @atomicLoad(?*Thread, &workers[worker_index].thread, .Acquire);
                const thread = thread_ptr orelse continue;
                if (thread == self)
                    continue;
                if (self.run_queue.tryStealFromLocal(&thread.run_queue, steal_next)) |runnable| {
                    return runnable;
                }
            }
        }

        return null;
    }
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

    pub const Batch = struct {
        head: ?*Runnable,
        tail: ?*Runnable,
        len: usize,

        pub fn init() Batch {
            return Batch{
                .head = null,
                .tail = null,
                .len = 0,
            };
        }

        pub fn from(runnable: *Runnable) Batch {
            var self = Batch.init();
            self.push(runnable);
            return self;
        }

        pub fn push(noalias self: *Batch, noalias runnable: *Runnable) void {
            if (self.head == null)
                self.head = runnable;
            if (self.tail) |tail|
                tail.next = runnable;
            self.tail = runnable;
            runnable.next = null;
            self.len += 1;
        }

        pub fn pop(self: *Batch) ?*Runnable {
            const runnable = self.head orelse return null;
            self.head = runnable.next;
            if (self.head == null)
                self.tail = null;
            return runnable;
        }

        pub fn schedule(self: Batch) void {
            return self._schedule(false);
        }

        pub fn scheduleNext(self: Batch) void {
            return self._schedule(true);
        }

        fn _schedule(self: Batch, store_next: bool) void {
            const thread = Thread.current orelse unreachable;
            return thread.schedule(self, store_next);
        }
    };
};

pub const Task = struct {
    runnable: Runnable,
    frame: anyframe,

    pub fn init(frame: anyframe) Task {
        return Task{
            .runnable = Runnable.init(Task.@"resume"),
            .frame = frame,
        };
    }

    fn @"resume"(runnable: *Runnable) callconv(.C) void {
        const task = @fieldParentPtr(Task, "runnable", runnable);
        resume task.frame;
    }

    pub fn schedule(self: *Task) void {
        return Runnable.Batch.from(&self.runnable).schedule();
    }

    pub fn scheduleNext(self: *Task) void {
        return Runnable.Batch.from(&self.runnable).scheduleNext();
    }

    pub fn yield() void {
        var task = Task.init(@frame());
        suspend {
            task.schedule();
        }
    }

    pub fn yieldNext() void {
        var task = Task.init(@frame());
        suspend {
            task.scheduleNext();
        }
    }
};

const LocalQueue = extern struct {
    head: usize,
    tail: usize align(CACHE_LINE),
    next: ?*Runnable,
    buffer: [256]*Runnable align(CACHE_LINE),

    fn init() LocalQueue {
        return LocalQueue{
            .head = 0,
            .tail = 0,
            .next = null,
            .buffer = undefined,
        };
    }

    fn deinit(self: *LocalQueue) void {
        defer self.* = undefined;
        if (!self.isEmpty())
            std.debug.panic("LocalQueue.deinit() when not-empty", .{});
    }

    fn isEmpty(self: *const LocalQueue) bool {
        while (true) {
            const head = @atomicLoad(usize, &self.head, .Acquire);
            const tail = @atomicLoad(usize, &self.tail, .Acquire);
            const next = @atomicLoad(?*Runnable, &self.next, .Acquire);
            if (tail == @atomicLoad(usize, &self.tail, .Monotonic))
                return (tail == head) and (next == null);
        }
    }

    fn pushWithOverflow(
        noalias self: *LocalQueue,
        noalias global_queue: *GlobalQueue,
        noalias runnable_ptr: *Runnable,
        store_next: bool,
    ) void {
        const runnable = blk: {
            if (!store_next)
                break :blk runnable_ptr;
            var next = @atomicLoad(?*Runnable, &self.next, .Acquire);
            while (true) {
                next = @cmpxchgWeak(
                    ?*Runnable,
                    &self.next,
                    next,
                    runnable_ptr,
                    .Acquire,
                    .Acquire,
                ) orelse break :blk next orelse return;
            }
        };

        const tail = self.tail;
        var head = @atomicLoad(usize, &self.head, .Acquire);
        
        while (true) {
            if (tail -% head < self.buffer.len) {
                self.buffer[tail % self.buffer.len] = runnable;
                @atomicStore(usize, &self.tail, tail +% 1, .Release);
                return;
            }

            if (tail -% head != self.buffer.len)
                std.debug.panic("LocalQueue.push() with inconsisitent size {}", .{tail -% head});

            var steal = self.buffer.len / 2;
            if (@cmpxchgWeak(
                usize,
                &self.head,
                head,
                head +% steal,
                .AcqRel,
                .Acquire,
            )) |new_head| {
                head = new_head;
                continue;
            }

            var batch = Runnable.Batch.init();
            while (steal != 0) : (steal -= 1) {
                batch.push(self.buffer[head % self.buffer.len]);
                head +%= 1;
            }

            batch.push(runnable);
            global_queue.push(batch);
            return;
        }
    }

    fn tryPop(self: *LocalQueue) ?*Runnable {
        var next = @atomicLoad(?*Runnable, &self.next, .Acquire);
        while (true) {
            const runnable = next orelse break;
            next = @cmpxchgWeak(
                ?*Runnable,
                &self.next,
                next,
                null,
                .AcqRel,
                .Acquire,
            ) orelse return runnable;
        }

        var head = @atomicLoad(usize, &self.head, .Acquire);
        const tail = self.tail;
        while (true) {
            if (tail == head)
                return null;

            head = @cmpxchgWeak(
                usize,
                &self.head,
                head,
                head +% 1,
                .AcqRel,
                .Acquire,
            ) orelse return self.buffer[head % self.buffer.len];
        }
    }

    fn tryStealFromLocal(
        noalias self: *LocalQueue,
        noalias target: *LocalQueue,
        steal_next: bool,
    ) ?*Runnable {
        const head = @atomicLoad(usize, &self.head, .Acquire);
        const tail = self.tail;

        // Occasionally, the local queue may not be empty for some reason ??
        // This doesn't seem to happen in exact SPMC implementations of other langs.
        if (tail != head) {
            if (tail -% head > self.buffer.len)
                std.debug.panic("LocalQueue.steal() with inconsistent buffer size = {} (head = {}, tail = {})", .{tail -% head, head, tail});
            return self.tryPop();
        }

        var target_head = @atomicLoad(usize, &target.head, .Acquire);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.tail, .Acquire);

            var steal = target_tail -% target_head;
            steal = steal - (steal / 2);

            if (steal == 0) {
                if (steal_next) {
                    if (@atomicLoad(?*Runnable, &target.next, .Acquire)) |next| {
                        _ = @cmpxchgWeak(
                            ?*Runnable,
                            &target.next,
                            next,
                            null,
                            .AcqRel,
                            .Acquire,
                        ) orelse return next;
                        std.SpinLock.loopHint(1);
                        continue;
                    }
                }
                return null;
            }

            const first_runnable = target.buffer[target_head % target.buffer.len];
            var new_target_head = target_head +% 1;
            var new_tail = tail;
            steal -= 1;

            while (steal != 0) : (steal -= 1) {
                const runnable = target.buffer[new_target_head % target.buffer.len];
                self.buffer[new_tail % self.buffer.len] = runnable;
                new_target_head +%= 1;
                new_tail +%= 1;
            }

            target_head = @cmpxchgWeak(
                usize,
                &target.head,
                target_head,
                new_target_head,
                .AcqRel,
                .Acquire,
            ) orelse {
                @atomicStore(usize, &self.tail, new_tail, .Release);
                return first_runnable;
            };
        }
    }

    fn tryStealFromGlobal(
        noalias self: *LocalQueue,
        noalias target: *GlobalQueue,
    ) ?*Runnable {
        if (@atomicLoad(bool, &target.is_polling, .Monotonic))
            return null;
        if (@atomicRmw(bool, &target.is_polling, .Xchg, true, .Acquire))
            return null;
        defer @atomicStore(bool, &target.is_polling, false, .Release);

        const first_runnable = target.pop();

        const head = @atomicLoad(usize, &self.head, .Acquire);
        const tail = self.tail;
        var new_tail = tail;

        var steal = self.buffer.len - (tail -% head);
        while (steal != 0) : (steal -= 1) {
            const runnable = target.pop() orelse break;
            self.buffer[new_tail % self.buffer.len] = runnable;
            new_tail +%= 1;
        }

        @atomicStore(usize, &self.tail, new_tail, .Release);
        return first_runnable;
    }
};

const GlobalQueue = extern struct {
    is_polling: bool,
    head: *Runnable align(CACHE_LINE),
    tail: *Runnable align(CACHE_LINE),
    stub_next: ?*Runnable,

    fn init(self: *GlobalQueue) void {
        const stub = @fieldParentPtr(Runnable, "next", &self.stub_next);
        self.stub_next = null;
        self.head = stub;
        self.tail = stub;
    }

    fn deinit(self: *GlobalQueue) void {
        defer self.* = undefined;
        if (@atomicLoad(bool, &self.is_polling, .Monotonic))
            std.debug.panic("GlobalQueue.deinit() while is_polling", .{});
        if (!self.isEmpty())
            std.debug.panic("GlobalQueue.deinit() when not empty", .{});
    }

    fn isEmpty(self: *const GlobalQueue) bool {
        const stub = @fieldParentPtr(Runnable, "next", &self.stub_next);
        const head = @atomicLoad(*Runnable, &self.head, .Monotonic);
        return head == stub;
    }

    fn push(self: *GlobalQueue, batch: Runnable.Batch) void {
        const head = batch.head orelse return;
        const tail = batch.tail orelse unreachable;

        tail.next = null;
        const prev = @atomicRmw(*Runnable, &self.head, .Xchg, tail, .AcqRel);
        @atomicStore(?*Runnable, &prev.next, head, .Release);
    }

    fn pop(self: *GlobalQueue) ?*Runnable {
        if (!self.is_polling)
            std.debug.panic("GlobalQueue.pop() when not is_polling", .{});

        var tail = self.tail;
        var next = @atomicLoad(?*Runnable, &tail.next, .Acquire);

        const stub = @fieldParentPtr(Runnable, "next", &self.stub_next);
        if (tail == stub) {
            tail = next orelse return null;
            self.tail = tail;
            next = @atomicLoad(?*Runnable, &tail.next, .Acquire); 
        }

        if (next) |next_tail| {
            self.tail = next_tail;
            return tail;
        }

        const head = @atomicLoad(*Runnable, &self.head, .Acquire);
        if (head != tail)
            return null;

        self.push(Runnable.Batch.from(stub));
        next = @atomicLoad(?*Runnable, &tail.next, .Acquire);
        self.tail = next orelse return null;
        return tail;
    }
};

const AtomicUsize = switch (std.builtin.arch) {
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
            self: *const AtomicUsize,
            comptime ordering: std.builtin.AtomicOrder,
        ) AtomicUsize {
            return AtomicUsize{
                .value = @atomicLoad(usize, &self.value, ordering),
                .aba_tag = @atomicLoad(usize, &self.aba_tag, .SeqCst),
            };
        }

        fn compareExchangeWeak(
            self: *AtomicUsize,
            compare: AtomicUsize,
            exchange: usize,
            comptime success: std.builtin.AtomicOrder,
            comptime failure: std.builtin.AtomicOrder,
        ) ?AtomicUsize {
            const double_word = @cmpxchgWeak(
                DoubleWord,
                @ptrCast(*DoubleWord, self),
                @bitCast(DoubleWord, compare),
                @bitCast(DoubleWord, AtomicUsize{
                    .value = exchange,
                    .aba_tag = compare.aba_tag +% 1,
                }),
                success,
                failure,
            ) orelse return null;
            return @bitCast(AtomicUsize, double_word);
        }
    },
    else => extern struct {
        value: usize,

        fn load(
            self: *const AtomicUsize,
            comptime ordering: std.builtin.AtomicOrder,
        ) AtomicUsize {
            const value = @atomicLoad(usize, &self.value, ordering);
            return AtomicUsize{ .value = value };
        }

        fn compareExchangeWeak(
            self: *AtomicUsize,
            compare: AtomicUsize,
            exchange: usize,
            comptime success: std.builtin.AtomicOrder,
            comptime failure: std.builtin.AtomicOrder,
        ) ?AtomicUsize {
            const value = @cmpxchgWeak(
                usize,
                &self.value,
                compare.value,
                exchange,
                success,
                failure,
            ) orelse return null;
            return AtomicUsize{ .value = value };
        }
    },
};