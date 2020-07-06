const std = @import("std");

pub const Scheduler = struct {
    pub const Config = struct {
        max_workers: usize = std.math.maxInt(usize),
    };

    const IDLE_NOTIFIED = 1;
    const IDLE_SHUTDOWN = 2;

    active_threads: usize,
    idle_queue: AtomicUsize,
    run_queue: GlobalQueue,
    workers: []Worker,

    pub fn run(config: Config, comptime func: var, args: var) !@TypeOf(func).ReturnType {
        var num_workers = if (std.builtin.single_threaded) 1 else (std.Thread.cpuCount() catch 1);
        num_workers = std.math.max(1, std.math.max(config.max_workers, num_workers));

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
            .idle_queue = AtomicUsize{ .value = 0 },
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
                if (worker.handle) |thread_handle|
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

        self.run_queue.push(&task);
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
                next_value = @atomicLoad(usize, &worker.value, .Unordered);
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
            const is_main_thread = @atomicRmw(usize, &self.active_threads, .Add, 1, .SeqCst);

            worker.next = @ptrToInt(self);
            if (is_main_thread) {
                Thread.run(worker);
                return;
            }

            if (std.Thread.spawn(worker, Thread.run)) |handle| {
                // TODO
            }
        }
    }

    fn suspendThread(
        noalias self: *Scheduler,
        noalias worker: *Worker,
    ) void {

    }

    fn shutdown(self: *Scheduler) void {

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
        const sceduler = @intToPtr(*Scheduler, worker.next);
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
        while (true) {

            if (self.poll(scheduler, &rng, tick)) |task| {
                tick +%= 1;
                resume task.frame;
                continue;
            }

            scheduler.suspendThread(worker);
            self.event.wait();
            self.event.reset();
            if (self.scheduler == null)
                break;
        }
    }

    fn schedule(self: *Thread, task: *Task) void {
        const scheduler = self.scheduler orelse unreachable;

        if (self.run_queue.tryPush(task) == false)
            scheduler.push(task);

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

        const slots = scheduler.slots;
        var steal_attempts: u3 = 4;
        while (steal_attempts != 0) : (steal_attempts -= 1) {

            if (self.run_queue.tryStealFromGlobal(&scheduler.run_queue)) |task| {
                scheduler.resumeThread();
                return task;
            }

            var slot_index = blk: {
                var rng = rng_ptr.*;
                rng ^= rng << 13;
                rng ^= rng >> 17;
                rng ^= rng << 5;
                rng_ptr.* = rng;
                break :blk (rng % slots.len);
            };

            var slot_iter = slots.len;
            while (slot_iter != 0) : (slot_iter -= 1) {
                const slot_ptr = @atomicLoad(usize, &slots[slot_index].ptr, .Acquire);
                slot_index += 1;
                if (slot_index == slots.len)
                    slot_index = 0;

                switch (Slot.decode(slot_ptr)) {
                    .slot, .handle, .scheduler => {},
                    .thread => |thread| {
                        if (thread == self)
                            continue;
                        if (self.run_queue.tryStealFromLocal(&thread.run_queue)) |task| {
                            return task;
                        }
                    }
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
        const thread = Thread.current orelse unreachable;
        return thread.schedule(self);
    }

    pub fn yield() void {
        var task = Task.init(@frame());
        suspend {
            task.schedule();
        }
    }
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

    fn tryPush(noalias self: *LocalQueue, noalias task: *Task) bool {
        const head = @atomicLoad(usize, &self.head, .Monotonic);
        const tail = @atomicLoad(usize, &self.tail, .Monotonic);

        const is_full = tail -% head == self.buffer.len;
        if (!is_full) {
            self.buffer[tail % self.buffer.len] = task;
            @atomicStore(usize, &self.tail, tail +% 1, .Release);
        }

        return !is_full;
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

    fn tryStealFromLocal(noalias self: *LocalQueue, noalias target: *LocalQueue) ?*Task {
        const head = @atomicLoad(usize, &self.head, .Monotonic);
        const tail = self.tail;
        std.debug.assert(tail == head);

        var target_head = @atomicLoad(usize, &target.head, .Acquire);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.head, .Acquire);

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

    fn tryStealFromGlobal(noalias self: *LocalQueue, noalias target: *GlobalQueue) ?*Task {
        if (@atomicLoad(bool, &target.is_locked, .Monotonic))
            return null;
        if (@atomicRmw(bool, &target.is_locked, .Xchg, true, .Acquire))
            return null;
        defer @atomicStore(bool, &target.is_locked, false, .Release);

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
        std.debug.assert(@atomicLoad(bool, &self.is_locked, .Monotonic) == false);
    }

    fn isEmpty(self: *const GlobalQueue) bool {
        const stub = @fieldParentPtr(Task, "next", &self.stub_next);
        const head = @atomicLoad(*Task, &self.head, .Monotonic);
        return head == stub;
    }

    fn push(noalias self: *GlobalQueue, noalias task: *Task) void {
        task.next = null;
        const prev = @atomicRmw(*Task, &self.head, .Xchg, task, .AcqRel);
        @atomicStore(?*Task, &prev.next, task, .Release);
    }

    fn pop(self: *GlobalQueue) ?*Task {
        std.debug.assert(self.is_locked);
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

        self.push(stub);
        next = @atomicLoad(?*Task, &tail.next, .Acquire);
        self.tail = next orelse return null;
        return tail;
    }
};

const AtomicUsize = switch (std.builtin.arch) {
    .i386, .x86_64 => extern struct {
        value: usize align(@alignOf(DoubleWord)),
        aba_tag: usize = 0,

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