const std = @import("std");

pub const Scheduler = struct {
    pub const Config = struct {
        max_workers: usize = 0,
        max_threads: usize = 0,
        allocator: ?*std.mem.Allocator = null,
    };

    pub fn runAsync(config: Config, comptime func: var, args: var) !@TypeOf(func).ReturnType {
        const ReturnType = @TypeOf(func).ReturnType;
        const Wrapper = struct {
            fn entry(func_args: var, task: *Task, result: *?ReturnType) void {
                suspend task.* = Task.init(@frame());
                const res = @call(.{}, func, func_args);
                result.* = res;
            }
        };

        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.entry(args, &task, &result);
        try run(config, &task.runnable);
        return result orelse error.DeadLocked;
    }

    pub fn run(config: Config, runnable: *Runnable) !void {
        var max_threads = config.max_threads;
        var max_workers = config.max_workers;

        if (std.builtin.single_threaded)
            max_threads = std.math.min(1, max_threads);
        if (max_workers == 0)
            max_workers = std.Thread.cpuCount() catch 1;
        if (max_threads == 0)
            max_threads = max_workers + 64;
        if (max_workers > max_threads)
            max_workers = max_threads;

        if (std.builtin.single_threaded or max_workers == 1) {
            var workers = [_]Worker{undefined};
            var threads = [0]?*std.Thread{};
            return runUsing(workers[0..], threads[0..], runnable);
        }

        const allocator = config.allocator orelse
            if (std.builtin.link_libc) std.heap.c_allocator
            else std.heap.page_allocator;

        const memory = try allocator.alloc(usize, max_workers + (max_threads - 1));
        defer allocator.free(memory);
        const workers = @ptrCast([*]Worker, memory.ptr)[0..max_workers];
        const threads = @ptrCast([*]?*std.Thread, memory.ptr + max_workers)[0..(max_threads - 1)];
        return runUsing(workers, threads, runnable);
    }

    const Mutex = std.Mutex;

    lock: Mutex,
    runq: Runnable.Batch,
    runq_size: usize,

    threads: []?*std.Thread,
    idle_threads: ?*Thread,
    active_threads: usize,
    free_threads: usize,
    
    workers: []Worker,
    idle_workers: ?*Worker,
    active_workers: usize,
    searching_workers: usize,

    pub fn runUsing(workers: []Worker, threads: []?*std.Thread, runnable: *Runnable) !void {
        if (workers.len == 0 or threads.len == 0)
            return;

        var self = Scheduler{
            .lock = Mutex.init(),
            .runq = Runnable.Batch.from(runnable),
            .runq_size = 1,
            .threads = threads,
            .idle_threads = null,
            .active_threads = 0,
            .free_threads = threads.len,
            .workers = workers,
            .idle_workers = null,
            .active_workers = 0,
            .searching_workers = 0,
        };

        for (threads) |*thread|
            thread.* = null;
        for (workers) |*worker| {
            worker.* = @ptrToInt(self.idle_workers) | 1;
            self.idle_workers = worker;
        }

        self.resumeThread(null);
        for (threads) |thread| {
            (thread orelse continue).wait();
        }

        const held = self.lock.tryAcquire() orelse unreachable;
        defer {
            held.release();
            self.lock.deinit();
        }

        std.debug.assert(self.runq_size == 0);
        std.debug.assert(self.idle_threads == null);
        std.debug.assert(self.active_threads == 0);
        std.debug.assert(self.free_threads == threads.len);
        std.debug.assert(self.active_workers == 0);
        std.debug.assert(self.searching_workers == 0);
    }

    fn schedule(self: *Scheduler, batch: Runnable.Batch) void {
        if (batch.len == 0)
            return;

        const held = self.lock.acquire();
        self.runq.pushBatch(batch);
        @atomicStore(usize, &self.runq_size, self.runq_size + batch.len, .Release);

        if (@atomicLoad(usize, &self.searching_workers, .Monotonic) == 0) {
            self.resumeThread(held);
        } else {
            held.release();
        }
    }

    fn resumeThread(self: *Scheduler, current_held: ?Mutex.Held) void {
        if (@cmpxchgStrong(usize, &self.searching_workers, 0, 1, .AcqRel, .Monotonic) != null) {
            if (current_held) |held|
                held.release();
            return;
        }

        const held = current_held orelse self.lock.acquire();

        if (self.idle_workers) |idle_worker| {
            const worker = idle_worker;
            self.idle_workers = @intToPtr(?*Worker, worker.* & ~@as(usize, 1));
            self.active_threads += 1;
            @atomicStore(usize, &self.active_workers, self.active_workers + 1, .Release);

            if (self.idle_threads) |idle_thread| {
                const thread = idle_thread;
                self.idle_threads = thread.next;
                held.release();
                thread.worker = worker;
                thread.is_searching = true;
                return thread.event.set();
            }

            @atomicStore(Worker, worker, @ptrToInt(self) | 1, .Monotonic);
            if (self.active_threads == 1) {
                held.release();
                return Thread.run(@ptrToInt(worker) | 1);
            }

            if (self.free_threads != 0) {
                if (std.Thread.spawn(@ptrToInt(worker), Thread.run)) |thread_handle| {
                    self.threads[self.threads.len - self.free_threads] = thread_handle;
                    self.free_threads -= 1;
                    return held.release();
                } else |_| {}
            }

            @atomicStore(Worker, worker, @ptrToInt(self.idle_workers) | 1, .Monotonic);
            self.idle_workers = worker;
            self.active_threads -= 1;
            @atomicStore(usize, &self.active_workers, self.active_workers - 1, .Release);
        }

        _ = @atomicRmw(usize, &self.searching_workers, .Sub, 1, .Release);
        return held.release();
    }
};

pub const Worker = usize;

pub const Thread = struct {
    pub threadlocal var current: ?*Thread = null;

    next: ?*Thread,
    worker: ?*Worker,
    scheduler: *Scheduler,
    event: std.ResetEvent,
    is_searching: bool,
    runq_next: ?*Runnable,
    runq_head: usize,
    runq_tail: usize,
    runq_buffer: [256]*Runnable,

    fn run(worker_ptr: usize) void {
        const is_main_thread = worker_ptr & 1 != 0;
        const starting_worker = @intToPtr(*Worker, worker_ptr & ~@as(usize, 1));
        const scheduler = @intToPtr(*Scheduler, starting_worker.* & ~@as(usize, 1));
        var self = Thread{
            .next = undefined,
            .worker = starting_worker,
            .scheduler = scheduler,
            .event = std.ResetEvent.init(),
            .is_searching = true,
            .runq_next = null,
            .runq_head = 0,
            .runq_tail = 0,
            .runq_buffer = undefined,
        };

        Thread.current = &self;
        defer {
            self.event.deinit();
            std.debug.assert(!self.is_searching);
            std.debug.assert(self.isQueueEmpty());
            if (!is_main_thread)
                _ = @atomicRmw(usize, &scheduler.free_threads, .Add, 1, .Release);
        }

        var tick: u8 = 0;
        var rng = @truncate(u32, @ptrToInt(&self) ^ @ptrToInt(starting_worker));
        
        while (true) {
            const worker = self.worker orelse break;
            @atomicStore(Worker, worker, @ptrToInt(&self), .Release);

            while (true) {
                const runnable = self.poll(scheduler, &rng, tick) orelse break;
                
                if (self.is_searching) {
                    self.is_searching = false;
                    if (@atomicRmw(usize, &scheduler.searching_workers, .Sub, 1, .Release) == 1)
                        scheduler.resumeThread(null);
                }

                tick +%= 1;
                (runnable.callback)(runnable);
            }
        }
    }

    fn poll(
        noalias self: *Thread,
        noalias scheduler: *Scheduler,
        noalias rng_ptr: *u32,
        tick: u8,
    ) ?*Runnable {
        if (tick % 61 == 0) {
            if (self.pollGlobal(scheduler, null)) |runnable|
                return runnable;
        }

        if (self.pollLocal()) |runnable|
            return runnable;

        if (self.pollGlobal(scheduler, null)) |runnable|
            return runnable;

        if (!self.is_searching) {
            const searching_workers = @atomicLoad(usize, &scheduler.searching_workers, .Acquire);
            const active_workers = @atomicLoad(usize, &scheduler.active_workers, .Monotonic);
            if (searching_workers * 2 >= active_workers) {
                self.is_searching = true;
                _ = @atomicRmw(usize, &scheduler.searching_workers, .Add, 1, .AcqRel);
            }
        }

        if (self.is_searching) {
            const num_workers = scheduler.workers.len;
            var attempts: u3 = 4;
            while (attempts != 0) : (attempts -= 1) {
                const steal_next = attempts < 2;

                var index = blk: {
                    var x = rng_ptr.*;
                    x ^= x << 13;
                    x ^= x >> 17;
                    x ^= x << 5;
                    rng_ptr.* = x;
                    break :blk x % num_workers;
                };

                var iter = num_workers;
                while (iter != 0) : (iter -= 1) {
                    const thread_ptr = @atomicLoad(Worker, &scheduler.workers[index], .Acquire);
                    if (thread_ptr & 1 == 0) {
                        if (@intToPtr(?*Thread, thread_ptr & ~@as(usize, 1))) |thread| {
                            if (self.pollSteal(thread, steal_next)) |runnable|
                                return runnable;
                        }
                    }

                    index += 1;
                    if (index == num_workers)
                        index = 0;
                }
            }
        }

        {
            const held = scheduler.lock.acquire();
            defer held.release();
            if (self.pollGlobal(scheduler, held)) |runnable|
                return runnable;

            const worker = self.worker.?;
            @atomicStore(usize, &scheduler.active_workers, scheduler.active_workers - 1, .Monotonic);
            @atomicStore(Worker, worker, @ptrToInt(scheduler.idle_workers) | 1, .Monotonic);
            scheduler.idle_workers = worker;
            self.worker = null;
        }

        const was_searching = self.is_searching;
        if (was_searching) {
            self.is_searching = false;
            _ = @atomicRmw(usize, &scheduler.searching_workers, .Sub, 1, .AcqRel);
        }

        for (scheduler.workers) |*worker| {
            const thread_ptr = @atomicLoad(usize, worker, .Acquire);
            if (thread_ptr & 1 != 0)
                continue;
            const thread = @intToPtr(?*Thread, thread_ptr) orelse continue;
            if (thread.isQueueEmpty())
                continue;

            self.worker = blk: {
                const held = scheduler.lock.acquire();
                defer held.release();
                const idle_worker = scheduler.idle_workers orelse break :blk null;
                scheduler.idle_workers = @intToPtr(?*Worker, idle_worker.* & ~@as(usize, 1));
                break :blk idle_worker;
            };

            _ = self.worker orelse break;
            self.is_searching = was_searching;
            if (was_searching)
                _ = @atomicRmw(usize, &scheduler.searching_workers, .Add, 1, .Acquire);
            return null;
        }

        const held = scheduler.lock.acquire();
        var idle_threads = scheduler.idle_threads;
        scheduler.active_threads -= 1;

        if (scheduler.active_threads == 0) {
            scheduler.idle_threads = null;
            held.release();
            while (idle_threads) |idle_thread| {
                const thread = idle_thread;
                idle_threads = thread.next;
                thread.worker = null;
                @fence(.Release);
                thread.event.set();
            }

        } else {
            self.next = idle_threads;
            scheduler.idle_threads = self;
            held.release();
            self.event.wait();
            self.event.reset();
            @fence(.Acquire);
        }

        return null;
    }

    fn isQueueEmpty(self: *const Thread) bool {
        while (true) {
            const head = @atomicLoad(usize, &self.runq_tail, .Acquire);
            const tail = @atomicLoad(usize, &self.runq_head, .Acquire);
            const next = @atomicLoad(?*Runnable, &self.runq_next, .Acquire);
            if (tail == @atomicLoad(usize, &self.runq_tail, .Monotonic))
                return (tail == head) and (next == null);
        }
    }

    fn pollGlobal(
        noalias self: *Thread,
        noalias scheduler: *Scheduler,
        current_held: ?Scheduler.Mutex.Held,
    ) ?*Runnable {
        var is_local_held = false;
        const held = current_held orelse blk: {
            if (@atomicLoad(usize, &scheduler.runq_size, .Monotonic) == 0)
                return null;
            is_local_held = true;
            break :blk scheduler.lock.acquire();
        };
        defer if (is_local_held)
            held.release();

        const runnable = scheduler.runq.pop() orelse return null;
        var runq_size = scheduler.runq_size - 1;

        var tail = self.runq_tail;
        const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        while (tail -% head < self.runq_buffer.len) {
            const next_runnable = scheduler.runq.pop() orelse break;
            self.runq_buffer[tail % self.runq_buffer.len] = next_runnable;
            runq_size -= 1;
            tail +%= 1;
        }

        if (tail != self.runq_tail)
            @atomicStore(usize, &self.runq_tail, tail, .Release);
        @atomicStore(usize, &scheduler.runq_size, runq_size, .Release);
        return runnable;
    }

    fn pollLocal(self: *Thread) ?*Runnable {
        var next = @atomicLoad(?*Runnable, &self.runq_next, .Monotonic);
        while (next) |runnable| {
            next = @cmpxchgWeak(
                ?*Runnable,
                &self.runq_next,
                next,
                null,
                .Monotonic,
                .Monotonic,
            ) orelse return runnable;
        }

        const tail = self.runq_tail;
        var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        while (tail != head) {
            head = @cmpxchgWeak(
                usize,
                &self.runq_head,
                head,
                head +% 1,
                .Monotonic,
                .Monotonic,
            ) orelse return self.runq_buffer[head % self.runq_buffer.len];
        }

        return null;
    }

    fn pollSteal(
        noalias self: *Thread,
        noalias target: *Thread,
        steal_next: bool,
    ) ?*Runnable {
        var target_head = @atomicLoad(usize, &target.runq_head, .Acquire);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.runq_tail, .Acquire);

            var steal = target_tail -% target_head;
            steal = steal - (steal / 2);
            if (steal == 0)
                return null;

            const runnable = target.runq_buffer[target_head % target.runq_buffer.len];
            var new_target_head = target_head +% 1;
            steal -= 1;

            var tail = self.runq_tail;
            while (steal != 0) : (steal -= 1) {
                const next_runnable = target.runq_buffer[new_target_head % target.runq_buffer.len];
                self.runq_buffer[tail % self.runq_buffer.len] = next_runnable;
                new_target_head +%= 1;
                tail +%= 1;
            }

            target_head = @cmpxchgWeak(
                usize,
                &target.runq_head,
                target_head,
                new_target_head,
                .AcqRel,
                .Acquire,
            ) orelse {
                @atomicStore(usize, &self.runq_tail, tail, .Release);
                return runnable;
            };
        }
    }

    fn schedule(self: *Thread, batch: Runnable.Batch) void {
        var runnable = batch.head orelse return;
        const scheduler = self.scheduler;

        if (runnable != batch.tail)
            return scheduler.schedule(batch);

        var next = @atomicLoad(?*Runnable, &self.runq_next, .Monotonic);
        while (true) {
            next = @cmpxchgWeak(
                ?*Runnable,
                &self.runq_next,
                next,
                runnable,
                .Release,
                .Monotonic,
            ) orelse {
                runnable = next orelse {
                    if (@atomicLoad(usize, &scheduler.searching_workers, .Monotonic) == 0)
                        scheduler.resumeThread(null);
                    return;
                };
                break;
            };
        }
        
        const tail = self.runq_tail;
        var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        while (true) {

            if (tail -% head < self.runq_buffer.len) {
                self.runq_buffer[tail % self.runq_buffer.len] = runnable;
                @atomicStore(usize, &self.runq_tail, tail +% 1, .Release);
                if (@atomicLoad(usize, &scheduler.searching_workers, .Monotonic) == 0)
                    scheduler.resumeThread(null);
                return;
            }
            
            const new_head = head +% (self.runq_buffer.len / 2);
            if (@cmpxchgWeak(
                usize,
                &self.runq_head,
                head,
                new_head,
                .Release,
                .Monotonic,
            )) |updated_head| {
                head = updated_head;
                continue;
            }

            var overflow = Runnable.Batch{};
            while (head != new_head) {
                overflow.push(self.runq_buffer[head % self.runq_buffer.len]);
                head +%= 1;
            }
            overflow.push(runnable);
            return scheduler.schedule(overflow);
        }
    }
};

pub const Runnable = struct {
    next: ?*Runnable = undefined,
    callback: Callback,

    pub fn init(callback: Callback) Runnable {
        return Runnable{ .callback = callback };
    }

    pub const Callback = fn(*Runnable) callconv(.C) void;

    pub const Batch = struct {
        head: ?*Runnable = null,
        tail: ?*Runnable = null,
        len: usize = 0,

        pub fn from(runnable: *Runnable) Batch {
            var self = Batch{};
            self.push(runnable);
            return self;
        }

        pub fn pushBatch(self: *Batch, other: Batch) void {
            if (other.len == 0)
                return;
            if (self.head == null)
                self.head = other.head;
            if (self.tail) |tail|
                tail.next = other.head;
            self.tail = other.tail;
            self.len += other.len;
        }

        pub fn push(self: *Batch, runnable: *Runnable) void {
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
            self.len -= 1;
            return runnable;
        }

        pub fn schedule(self: Batch) void {
            if (Thread.current) |thread| {
                thread.schedule(self);
            } else {
                std.debug.panic("Runnable.Batch.schedule() outside Scheduler", .{});
            }
        }
    };
};

pub const Task = struct {
    runnable: Runnable = Runnable.init(@"resume"),
    frame: anyframe,

    pub fn init(frame: anyframe) Task {
        return Task{ .frame = frame };
    }

    fn @"resume"(runnable: *Runnable) callconv(.C) void {
        const task = @fieldParentPtr(Task, "runnable", runnable);
        resume task.frame;
    }

    pub fn schedule(self: *Task) void {
        return Runnable.Batch.from(&self.runnable).schedule();
    }

    pub fn yield() void {
        var task = Task.init(@frame());
        suspend task.schedule();
    }
};
