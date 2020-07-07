const std = @import("std");

pub const Scheduler = struct {
    pub const Config = struct {
        max_workers: usize = std.math.maxInt(usize),
    };

    const IDLE_EMPTY = 0;
    const IDLE_NOTIFIED = 1;
    const IDLE_SHUTDOWN = 2;

    active_threads: usize,
    idle_queue: AtomicUsize,
    run_queue: GlobalQueue,
    workers: []Worker,

    pub fn run(config: Config, comptime func: var, args: var) !@TypeOf(func).ReturnType {
        var num_workers = if (std.builtin.single_threaded) 1 else (std.Thread.cpuCount() catch 1);
        num_workers = std.math.max(1, std.math.min(config.max_workers, num_workers));

        if (num_workers <= 8) {
            var workers: [8]Worker = undefined;
            return runUsing(workers[0..num_workers], func, args);
        }

        const allocator = if (std.builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;
        const workers = try allocator.alloc(Worker, num_workers);
        defer allocator.free(workers);
        return runUsing(workers, func, args);
    }

    fn runUsing(workers: []Worker, comptime func: var, args: var) !@TypeOf(func).ReturnType {
        var self = Scheduler{
            .active_threads = 0,
            .idle_queue = AtomicUsize{ .value = IDLE_EMPTY },
            .run_queue = undefined,
            .workers = workers,
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
            std.debug.assert(@atomicLoad(usize, &self.active_threads, .Monotonic) == 0);
            std.debug.assert(self.idle_queue.load(.Monotonic).value == IDLE_SHUTDOWN);
            self.run_queue.deinit();
            for (workers) |*worker| {
                const handle_ptr = @atomicLoad(?*std.Thread, &worker.handle, .Acquire);
                const thread_handle = handle_ptr orelse continue;
                thread_handle.wait();
            }
        }

        const ReturnType = @TypeOf(func).ReturnType;
        const Wrapper = struct {
            fn call(func_args: var, task: *Task, result: *?ReturnType) void {
                suspend task.* = Task.init(@frame());
                const value = @call(.{}, func, func_args);
                result.* = value;
            }
        };

        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.call(args, &task, &result);
    
        self.run_queue.push(blk: {
            var batch = Task.Batch.init();
            batch.push(&task);
            break :blk batch;
        });
        self.resumeThread();

        return result orelse error.DeadLocked;
    }

    fn resumeThread(self: *Scheduler) void {
        var idle_queue = self.idle_queue.load(.Acquire);
        while (true) {
            std.debug.assert(idle_queue.value != IDLE_SHUTDOWN);
            if (idle_queue.value == IDLE_NOTIFIED)
                return;
            
            const worker_ptr = @intToPtr(?*Worker, idle_queue.value);
            var next_value: usize = undefined;
            if (worker_ptr) |worker| {
                next_value = @atomicLoad(usize, &worker.next, .Unordered);
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
            const is_main_thread = @atomicRmw(usize, &self.active_threads, .Add, 1, .SeqCst) == 0;

            worker.next = @ptrToInt(self);
            if (is_main_thread) {
                Thread.run(worker);
                return;
            }

            if (worker.thread) |thread| {
                thread.event.set();
                return;
            }

            if (std.Thread.spawn(worker, Thread.run)) |handle| {
                @atomicStore(?*std.Thread, &worker.handle, handle, .Release);
                return;
            } else |err| {
                _ = @atomicRmw(usize, &self.active_threads, .Sub, 1, .SeqCst);
            }

            idle_queue = self.idle_queue.load(.Monotonic);
            while (true) {
                worker.next = idle_queue.value;
                if (worker.next == IDLE_NOTIFIED)
                    worker.next = IDLE_EMPTY;
                idle_queue = self.idle_queue.compareExchangeWeak(
                    idle_queue,
                    @ptrToInt(worker),
                    .Release,
                    .Monotonic,
                ) orelse return;
            }
        }
    }

    fn suspendThread(
        noalias self: *Scheduler,
        noalias worker: *Worker,
    ) void {
        var idle_queue = self.idle_queue.load(.Monotonic);
        while (true) {
            std.debug.assert(idle_queue.value != IDLE_SHUTDOWN);

            var next_value: usize = undefined;
            if (idle_queue.value == IDLE_NOTIFIED) {
                next_value = IDLE_EMPTY;
            } else {
                next_value = @ptrToInt(worker);
                @atomicStore(usize, &worker.next, idle_queue.value, .Unordered);
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
                const thread = worker.thread orelse unreachable;
                thread.event.set();
                return;
            }

            const active_threads = @atomicRmw(usize, &self.active_threads, .Sub, 1, .SeqCst);
            if (active_threads == 1)
                self.shutdown();
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
        
        var num_workers: usize = 0;
        while (true) {
            const worker = @intToPtr(?*Worker, idle_queue) orelse break;
            idle_queue = worker.next;
            num_workers += 1;
            
            const thread = worker.thread orelse continue;
            thread.scheduler = null;
            thread.event.set();
        }
        
        std.debug.assert(num_workers == self.workers.len);
    }
};

const Worker = struct {
    next: usize,
    thread: ?*Thread,
    handle: ?*std.Thread,
};

const Thread = struct {
    threadlocal var current: ?*Thread = null;

    event: std.ResetEvent,
    run_queue: LocalQueue,
    scheduler: ?*Scheduler,

    fn run(worker: *Worker) void {
        const scheduler = @intToPtr(*Scheduler, worker.next);
        var self = Thread{
            .event = std.ResetEvent.init(),
            .run_queue = LocalQueue.init(),
            .scheduler = scheduler,
        };

        defer {
            self.event.deinit();
            self.run_queue.deinit();
        }

        Thread.current = &self;
        @atomicStore(?*Thread, &worker.thread, &self, .Release);

        var tick: u8 = 0;
        var rng = @truncate(u32, @ptrToInt(&self));
        while (self.scheduler != null) {

            if (self.poll(scheduler, &rng, tick)) |task| {
                tick +%= 1;
                resume task.frame;
                continue;
            }

            scheduler.suspendThread(worker);
            self.event.wait();
            self.event.reset();
        }
    }

    fn schedule(self: *Thread, batch: Task.Batch) void {
        const scheduler = self.scheduler orelse unreachable;

        switch (batch.len) {
            0 => return,
            1 => self.run_queue.pushWithOverflow(&scheduler.run_queue, batch.head.?),
            else => scheduler.run_queue.push(batch),
        }
        
        scheduler.resumeThread();
    }

    fn poll(
        noalias self: *Thread,
        noalias scheduler: *Scheduler,
        noalias rng_ptr: *u32,
        tick: u8, 
    ) ?*Task {
        if (tick % 61 == 0) {
            if (self.run_queue.tryStealFromGlobal(&scheduler.run_queue)) |task| {
                scheduler.resumeThread();
                return task;
            }
        }

        if (self.run_queue.tryPop()) |task| {
            return task;
        }

        const workers = scheduler.workers;
        var steal_attempts: u3 = 4;
        while (steal_attempts != 0) : (steal_attempts -= 1) {

            if (self.run_queue.tryStealFromGlobal(&scheduler.run_queue)) |task| {
                scheduler.resumeThread();
                return task;
            }

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
                if (self.run_queue.tryStealFromLocal(&thread.run_queue)) |task| {
                    return task;
                }
            }
        }

        return null;
    }
};

pub const Task = struct {
    next: ?*Task,
    frame: anyframe,

    pub fn init(frame: anyframe) Task {
        return Task{
            .next = undefined,
            .frame = frame,
        };
    }

    pub fn schedule(self: *Task) void {
        var batch = Task.Batch.init();
        batch.push(self);
        batch.schedule();
    }

    pub fn yield() void {
        var task = Task.init(@frame());
        suspend {
            task.schedule();
        }
    }

    pub const Batch = struct {
        head: ?*Task,
        tail: ?*Task,
        len: usize,

        pub fn init() Batch {
            return Batch{
                .head = null,
                .tail = null,
                .len = 0,
            };
        }

        pub fn push(noalias self: *Batch, noalias task: *Task) void {
            if (self.head == null)
                self.head = task;
            if (self.tail) |tail|
                tail.next = task;
            self.tail = task;
            task.next = null;
            self.len += 1;
        }

        pub fn pop(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            if (self.head == null)
                self.tail = null;
            return task;
        }

        pub fn schedule(self: Batch) void {
            const thread = Thread.current orelse unreachable;
            return thread.schedule(self);
        }
    };
};

const LocalQueue = struct {
    head: usize,
    tail: usize,
    buffer: [256]*Task,

    fn init() LocalQueue {
        return LocalQueue{
            .head = 0,
            .tail = 0,
            .buffer = undefined,
        };
    }

    fn deinit(self: *LocalQueue) void {
        defer self.* = undefined;
        std.debug.assert(self.isEmpty());
    }

    fn isEmpty(self: *const LocalQueue) bool {
        const head = @atomicLoad(usize, &self.head, .Monotonic);
        const tail = @atomicLoad(usize, &self.tail, .Monotonic);
        return tail == head;
    }

    fn pushWithOverflow(
        noalias self: *LocalQueue,
        noalias global_queue: *GlobalQueue,
        noalias task: *Task,
    ) void {
        const tail = self.tail;
        var head = @atomicLoad(usize, &self.head, .Acquire);
        
        while (true) {
            if (tail -% head < self.buffer.len) {
                self.buffer[tail % self.buffer.len] = task;
                @atomicStore(usize, &self.tail, tail +% 1, .Release);
                return;
            }

            std.debug.assert(tail -% head == self.buffer.len);
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

            var batch = Task.Batch.init();
            while (steal != 0) : (steal -= 1) {
                batch.push(self.buffer[head % self.buffer.len]);
                head +%= 1;
            }

            batch.push(task);
            global_queue.push(batch);
            return;
        }
    }

    fn tryPop(self: *LocalQueue) ?*Task {
        var head = @atomicLoad(usize, &self.head, .Monotonic);
        const tail = self.tail;

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
            ) orelse return self.buffer[head % self.buffer.len];
        }
    }

    fn tryStealFromLocal(
        noalias self: *LocalQueue,
        noalias target: *LocalQueue,
    ) ?*Task {
        const head = @atomicLoad(usize, &self.head, .Monotonic);
        const tail = self.tail;
        std.debug.assert(tail == head);

        var target_head = @atomicLoad(usize, &target.head, .Acquire);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.tail, .Acquire);

            var steal = target_tail -% target_head;
            steal = steal - (steal / 2);
            if (steal == 0)
                return null;

            const first_task = target.buffer[target_head % target.buffer.len];
            var new_target_head = target_head +% 1;
            var new_tail = tail;
            steal -= 1;

            while (steal != 0) : (steal -= 1) {
                const task = target.buffer[new_target_head % target.buffer.len];
                self.buffer[new_tail % self.buffer.len] = task;
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
                return first_task;
            };
        }
    }

    fn tryStealFromGlobal(
        noalias self: *LocalQueue,
        noalias target: *GlobalQueue,
    ) ?*Task {
        if (@atomicLoad(bool, &target.is_polling, .Monotonic))
            return null;
        if (@atomicRmw(bool, &target.is_polling, .Xchg, true, .Acquire))
            return null;
        defer @atomicStore(bool, &target.is_polling, false, .Release);

        const first_task = target.pop();

        const head = @atomicLoad(usize, &self.head, .Monotonic);
        const tail = self.tail;
        var new_tail = tail;

        var steal = self.buffer.len - (tail -% head);
        while (steal != 0) : (steal -= 1) {
            const task = target.pop() orelse break;
            self.buffer[new_tail % self.buffer.len] = task;
            new_tail +%= 1;
        }

        @atomicStore(usize, &self.tail, new_tail, .Release);
        return first_task;
    }
};

const GlobalQueue = struct {
    is_polling: bool,
    head: *Task,
    tail: *Task,
    stub_next: ?*Task,

    fn init(self: *GlobalQueue) void {
        const stub = @fieldParentPtr(Task, "next", &self.stub_next);
        self.stub_next = null;
        self.head = stub;
        self.tail = stub;
    }

    fn deinit(self: *GlobalQueue) void {
        defer self.* = undefined;
        std.debug.assert(self.isEmpty());
        std.debug.assert(@atomicLoad(bool, &self.is_polling, .Monotonic) == false);
    }

    fn isEmpty(self: *const GlobalQueue) bool {
        const stub = @fieldParentPtr(Task, "next", &self.stub_next);
        const head = @atomicLoad(*Task, &self.head, .Monotonic);
        return head == stub;
    }

    fn push(self: *GlobalQueue, batch: Task.Batch) void {
        const head = batch.head orelse return;
        const tail = batch.tail orelse unreachable;

        tail.next = null;
        const prev = @atomicRmw(*Task, &self.head, .Xchg, tail, .AcqRel);
        @atomicStore(?*Task, &prev.next, head, .Release);
    }

    fn pop(self: *GlobalQueue) ?*Task {
        std.debug.assert(self.is_polling);
        var tail = self.tail;
        var next = @atomicLoad(?*Task, &tail.next, .Acquire);

        const stub = @fieldParentPtr(Task, "next", &self.stub_next);
        if (tail == stub) {
            tail = next orelse return null;
            self.tail = tail;
            next = @atomicLoad(?*Task, &tail.next, .Acquire); 
        }

        if (next) |next_tail| {
            self.tail = next_tail;
            return tail;
        }

        const head = @atomicLoad(*Task, &self.head, .Monotonic);
        if (head != tail)
            return null;

        self.push(blk: {
            var batch = Task.Batch.init();
            batch.push(stub);
            break :blk batch;
        });

        next = @atomicLoad(?*Task, &tail.next, .Acquire);
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