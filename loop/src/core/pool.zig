const std = @import("std");

pub fn Pool(comptime Platform: type) type {
    return extern struct {
        const WorkerPool = @This();

        active_workers: usize align(Platform.CACHE_LINE),
        running_workers: usize align(Platform.CACHE_LINE),
        idle_workers: usize align(Platform.CACHE_LINE),
        run_queue: Task.GlobalQueue,
        platform: *Platform,
        workers_ptr: [*]*Worker,
        workers_len: usize,
        stop_event: Platform.AutoResetEvent,

        pub fn run(platform: *Platform, workers: []*Worker, task: *Task) void {
            if (workers.len == 0)
                return;

            // TODO: separate path for single threaded

            var self = WorkerPool{
                .active_workers = 0,
                .running_workers = 0,
                .idle_workers = 0,
                .run_queue = undefined,
                .platform = platform,
                .workers_ptr = workers.ptr,
                .workers_len = workers.len,
                .stop_event = undefined,
            };

            self.stop_event.init();
            defer self.stop_event.deinit();

            self.run_queue.init();
            defer self.run_queue.deinit();

            for (workers) |worker|
                worker.init(&self);
            defer for (workers) |worker|
                worker.deinit();

            defer {
                const running_workers = @atomicLoad(usize, &self.running_workers, .Monotonic);
                const active_workers = @atomicLoad(usize, &self.active_workers, .Monotonic);

                if (running_workers != 0)
                    std.debug.panic("Pool.deinit(): {} pending running workers\n", .{running_workers});
                if (active_workers != 0)
                    std.debug.panic("Pool.deinit(): {} pending active workers\n", .{active_workers});
            }

            if (@intToPtr(?*Worker, self.idle_workers)) |idle_worker| {
                const worker = idle_worker;
                self.idle_workers = @ptrToInt(worker.next);
                
                self.active_workers = 1;
                self.running_workers = 1;
                self.run_queue.push(&Task.List.from(task));
                
                if (platform.runWorker(true, worker))
                    self.stop_event.wait();
            }
        }

        const WORKERS_RUNNING: usize = 0x1;
        const WORKERS_STOPPING: usize = 0x2;

        fn suspendWorker(self: *WorkerPool, worker: *Worker) void {
            var idle_workers = @atomicLoad(usize, &self.idle_workers, .Monotonic);
            while (true) {

                if (idle_workers == WORKERS_STOPPING) {
                    worker.state = .Stopping;
                    return;

                } else if (idle_workers == WORKERS_RUNNING) {
                    worker.state = .Running;
                    idle_workers = @cmpxchgWeak(
                        usize,
                        &self.idle_workers,
                        idle_workers,
                        0x0,
                        .Monotonic,
                        .Monotonic,
                    ) orelse return;

                } else {
                    worker.state = .Suspended;
                    worker.next = @intToPtr(?*Worker, idle_workers);
                    idle_workers = @cmpxchgWeak(
                        usize,
                        &self.idle_workers,
                        idle_workers,
                        @ptrToInt(worker),
                        .Release,
                        .Monotonic,
                    ) orelse {
                        const active_workers = @atomicRmw(usize, &self.active_workers, .Sub, 1, .Release);
                        if (active_workers == 1) {
                            self.shutdownWorkers();
                        } else {
                            worker.event.wait();
                        }
                        return;
                    };
                }
            }
        }

        fn resumeWorker(self: *WorkerPool) void {
            var idle_workers = @atomicLoad(usize, &self.idle_workers, .Acquire);
            while (true) {
                if (idle_workers == WORKERS_STOPPING)
                    std.debug.panic("Pool.resumeWorker() called while stopping\n", .{});

                if (idle_workers == WORKERS_RUNNING)
                    break;

                if (idle_workers == 0x0) {
                    idle_workers = @cmpxchgWeak(
                        usize,
                        &self.idle_workers,
                        idle_workers,
                        WORKERS_RUNNING,
                        .Acquire,
                        .Acquire,
                    ) orelse break;
                    continue;
                }

                const worker = @intToPtr(*Worker, idle_workers);
                if (@cmpxchgWeak(
                    usize,
                    &self.idle_workers,
                    idle_workers,
                    @ptrToInt(worker.next),
                    .Acquire,
                    .Acquire,
                )) |new_idle_workers| {
                    idle_workers = new_idle_workers;
                    continue;
                }

                _ = @atomicRmw(usize, &self.active_workers, .Add, 1, .Acquire);
                switch (worker.state) {
                    .Suspended => {
                        worker.state = .Searching;
                        worker.event.set(false);
                        return;
                    },
                    .Stopped => {
                        _ = @atomicRmw(usize, &self.running_workers, .Add, 1, .Acquire);
                        if (self.platform.runWorker(false, worker))
                            return;
                        _ = @atomicRmw(usize, &self.running_workers, .Sub, 1, .Release);
                        _ = @atomicRmw(usize, &self.active_workers, .Sub, 1, .Release);
                        break;
                    },
                    else => |state| {
                        std.debug.panic("Pool.resumeWorker(): unexpected state = {}\n", .{state});
                    },
                }
            }
        }

        fn shutdownWorkers(self: *WorkerPool) void {
            var idle_workers = @atomicRmw(usize, &self.idle_workers, .Xchg, WORKERS_STOPPING, .AcqRel);

            while (true) {
                switch (idle_workers) {
                    0x0, WORKERS_RUNNING => return,
                    WORKERS_STOPPING => {
                        std.debug.panic("Pool.shutdownWorkers() called more than once\n", .{});
                    },
                    else => {
                        const worker = @intToPtr(*Worker, idle_workers);
                        idle_workers = @ptrToInt(worker.next);
                        switch (worker.state) {
                            .Stopped => {},
                            .Stopping => {
                                std.debug.panic("Pool.shutdownWorkers() found idle Stopping worker\n", .{});
                            },
                            .Suspended => {
                                worker.state = .Stopping;
                                worker.event.set(false);
                            },
                            else => |state| {
                                std.debug.panic("Pool.shutdownWorkers() unexpected state = {}\n", .{state});
                            }
                        }
                    }
                }
            }
        }

        fn hasPendingTasks(self: *WorkerPool) bool {
            if (!self.run_queue.isEmpty())
                return true;
            for (self.workers_ptr[0..self.workers_len]) |worker| {
                if (worker.run_queue.len() != 0)
                    return true;
            }
            return false;
        }

        pub fn schedule(self: *WorkerPool, list: *Task.List) void {
            self.run_queue.push(list);
            self.resumeWorker();
        }

        pub const Worker = extern struct {
            const State = extern enum(u32) {
                Stopped,
                Stopping,
                Suspended,
                Searching,
                Running,
            };

            run_queue: Task.LocalQueue,
            pool: *WorkerPool,
            next: ?*Worker,
            state: State,
            rng_state: u32,
            event: Platform.AutoResetEvent,

            fn init(self: *Worker, pool: *WorkerPool) void {
                self.* = Worker{
                    .run_queue = undefined,
                    .pool = pool,
                    .next = @intToPtr(?*Worker, pool.idle_workers),
                    .state = .Stopped,
                    .rng_state = @truncate(u32, @ptrToInt(pool) ^ @ptrToInt(self)),
                    .event = undefined,
                };

                self.run_queue.init();
                pool.idle_workers = @ptrToInt(self);
            }

            fn deinit(self: *Worker) void {
                defer self.* = undefined;

                self.run_queue.deinit();
                if (self.state != .Stopped)
                    std.debug.panic("Worker.deinit() with state = {} instead of {}\n", .{self.state, State.Stopped});                    
            }

            pub fn schedule(self: *Worker, task: *Task) void {
                self.run_queue.push(task, &self.pool.run_queue);
                self.pool.resumeWorker();
            }

            pub fn run(self: *Worker) void {
                const pool = self.pool;
                const workers = pool.workers_ptr[0..pool.workers_len];
                const platform = pool.platform;

                self.event.init();
                self.state = .Searching;

                var iteration: usize = 0;
                while (self.findTask(iteration, pool, workers, platform)) |task| {
                    self.state = .Running;
                    iteration +%= 1;
                    (task.callback.*)(task, self);
                }

                self.event.deinit();
                switch (self.state) {
                    .Stopping => self.state = .Stopped,
                    else => |state| std.debug.panic("Worker.run(): stopping with state {}\n", .{state}),
                }

                const running_workers = @atomicRmw(usize, &pool.running_workers, .Sub, 1, .Release);
                if (running_workers == 1)
                    pool.stop_event.set(false);
            }

            fn findTask(
                self: *Worker,
                iteration: usize,
                pool: *WorkerPool,
                workers: []*Worker,
                platform: *Platform,
            ) ?*Task {
                var list = Task.List{};

                if (self.state != .Searching) {
                    platform.pollWorker(self, false, iteration, &list);
                    if (list.pop()) |task| {
                        pool.schedule(&list);
                        return task;
                    }

                    if (iteration % 61 == 0) {
                        if (pool.run_queue.poll()) |task|
                            return task;
                    }

                    if (self.run_queue.pop()) |task|
                        return task;
                }

                while (true) {
                    if (self.steal(pool, workers)) |task|
                        return task;

                    platform.pollWorker(self, true, iteration, &list);
                    if (list.pop()) |task| {
                        pool.schedule(&list);
                        return task;
                    }

                    pool.suspendWorker(self);
                    switch (self.state) {
                        .Stopping => return null,
                        .Searching, .Running => continue,
                        else => |state| std.debug.panic("Worker.findTask(): unexpected state = {}\n", .{state}),
                    }
                }
            }

            fn steal(self: *Worker, pool: *WorkerPool, workers: []*Worker) ?*Task {
                if (self.state != .Searching) {
                    self.state = .Searching;
                }
                
                const num_workers = workers.len;
                while (true) {
                    var steal_attempts: u4 = 0;
                    var stolen_task: ?*Task = null;
                    steal: while (steal_attempts < 4) : (steal_attempts += 1) {

                        stolen_task = pool.run_queue.stealInto(&self.run_queue);
                        if (stolen_task != null)
                            break :steal;

                        var rng_state = self.rng_state;
                        rng_state ^= rng_state << 13;
                        rng_state ^= rng_state >> 17;
                        rng_state ^= rng_state << 5;
                        self.rng_state = rng_state;

                        var worker_iter: usize = 0;
                        var worker_index = rng_state % num_workers;
                        while (worker_iter < num_workers) : (worker_iter += 1) {
                            const target = workers[worker_iter];

                            stolen_task = self.run_queue.stealFrom(&target.run_queue);
                            if (stolen_task != null)
                                break :steal;
                            
                            worker_index += 1;
                            if (worker_index >= num_workers)
                                worker_index = 0;
                        }
                    }

                    if (stolen_task != null) {
                        if (self.run_queue.len() != 0)
                            pool.resumeWorker();
                        return stolen_task;
                    } else if (pool.hasPendingTasks()) {
                        continue;
                    } else {
                        return null;
                    }
                }
            }
        };

        pub const Task = extern struct {
            next: ?*Task = null,
            callback: *const fn(*Task, *Worker) callconv(.C) void,

            pub const List = struct {
                head: ?*Task = null,
                tail: ?*Task = null,
                len: usize = 0,

                pub fn from(task: *Task) List {
                    var self = List{};
                    self.push(task);
                    return self;
                }

                pub fn push(self: *List, task: *Task) void {
                    if (self.tail) |tail|
                        tail.next = task;
                    if (self.head == null)
                        self.head = task;
                    self.tail = task;
                    task.next = null;
                    self.len += 1;
                }

                pub fn pop(self: *List) ?*Task {
                    const task = self.head orelse return null;
                    self.head = task.next;
                    if (self.head == null)
                        self.tail = null;
                    self.len -= 1;
                    return task;
                }
            };

            const GlobalQueue = extern struct {
                locked: bool align(Platform.CACHE_LINE),
                head: *Task align(Platform.CACHE_LINE),
                tail: *Task,
                stub: Task,

                fn init(self: *GlobalQueue) void {
                    self.stub.next = null;
                    self.head = &self.stub;
                    self.tail = &self.stub;
                    self.locked = false;
                }

                fn deinit(self: *GlobalQueue) void {
                    defer self.* = undefined;

                    const locked = @atomicLoad(bool, &self.locked, .Monotonic);
                    if (locked)
                        std.debug.panic("GlobalQueue.deinit() still locked\n", .{});
                    
                    if (self.tail != &self.stub)
                        std.debug.panic("GlobalQueue.deinit() with pending tasks\n", .{});
                }

                fn isEmpty(self: *const GlobalQueue) bool {
                    const head = @atomicLoad(*Task, &self.head, .Monotonic);
                    return head == &self.stub;
                }

                fn stealInto(self: *GlobalQueue, local_queue: *LocalQueue) ?*Task {
                    const acquired = switch (std.builtin.arch) {
                        .i386, .x86_64 => asm volatile(
                            "lock btsl $0, %[state]\n" ++
                            "setnc %[bit_is_now_set]"
                            : [bit_is_now_set] "=r" (-> bool)
                            : [state] "*m" (&self.locked)
                            : "cc", "memory"
                        ),
                        else => @cmpxchgStrong(
                            bool,
                            &self.locked,
                            false,
                            true,
                            .Acquire,
                            .Monotonic,
                        ) == null,
                    };
                    if (!acquired)
                        return null;
                    defer @atomicStore(bool, &self.locked, false, .Release);

                    const local_pos = @atomicLoad(usize, &local_queue.pos, .Monotonic);
                    const local_head = LocalQueue.decodeHead(local_pos);
                    const local_tail = LocalQueue.decodeTail(local_pos);
                    const size = LocalQueue.SIZE - (local_tail -% local_head);

                    var new_tail = local_tail;
                    var first_task: ?*Task = null;
                    
                    var stole: LocalQueue.Pos = 0;
                    while (stole < size) : (stole += 1) {
                        const task = self.pop() orelse break;
                        if (stole == 0) {
                            first_task = task;
                        } else {
                            local_queue.buffer[new_tail % LocalQueue.SIZE] = task;
                            new_tail +%= 1;
                        }
                    }

                    if (new_tail != local_tail)
                        @atomicStore(LocalQueue.Pos, local_queue.tailPtr(), new_tail, .Release);
                    return first_task;
                }

                fn poll(self: *GlobalQueue) ?*Task {
                    if (@cmpxchgStrong(bool, &self.locked, false, true, .Acquire, .Monotonic) != null)
                        return null;
                    defer @atomicStore(bool, &self.locked, false, .Release);

                    return self.pop();
                }

                fn pop(self: *GlobalQueue) ?*Task {
                    var tail = self.tail;
                    var next = @atomicLoad(?*Task, &tail.next, .Acquire);

                    if (tail == &self.stub) {
                        tail = next orelse return null;
                        self.tail = tail;
                        next = @atomicLoad(?*Task, &tail.next, .Acquire);
                    }

                    if (next) |next_task| {
                        self.tail = next_task;
                        return tail;
                    }

                    const head = @atomicLoad(?*Task, &self.head, .Monotonic);
                    if (head != tail)
                        return null;

                    self.push(&List.from(&self.stub));
                    self.tail = @atomicLoad(?*Task, &tail.next, .Acquire) orelse return null;
                    return tail;
                }

                fn push(self: *GlobalQueue, list: *List) void {
                    const head = list.head orelse return;
                    const tail = list.tail orelse return;
                    list.* = List{};

                    tail.next = null;
                    const prev = @atomicRmw(*Task, &self.head, .Xchg, tail, .AcqRel);
                    @atomicStore(?*Task, &prev.next, head, .Release);
                }
            };

            const LocalQueue = extern struct {
                const SIZE = Platform.LOCAL_QUEUE_SIZE;

                const Pos = @Type(std.builtin.TypeInfo{
                    .Int = std.builtin.TypeInfo.Int{
                        .bits = @typeInfo(usize).Int.bits / 2,
                        .is_signed = false,
                    },
                });

                pos: usize align(Platform.CACHE_LINE),
                buffer: [SIZE]*Task,
                
                fn init(self: *LocalQueue) void {
                    self.pos = 0;
                    self.buffer = undefined;
                }

                fn deinit(self: *LocalQueue) void {
                    defer self.* = undefined;

                    const size = self.len();
                    if (size != 0)
                        std.debug.panic("LocalQueue.deinit() with {} pending tasks\n", .{size});
                }

                fn encode(head: Pos, tail: Pos) usize {
                    return @bitCast(usize, [2]Pos{ head, tail });
                }

                fn decodeHead(pos: usize) Pos {
                    return @bitCast([2]Pos, pos)[0];
                }

                fn decodeTail(pos: usize) Pos {
                    return @bitCast([2]Pos, pos)[1];
                }

                fn headPtr(self: *LocalQueue) *Pos {
                    return &@ptrCast(*[2]Pos, &self.pos)[0];
                }

                fn tailPtr(self: *LocalQueue) *Pos {
                    return &@ptrCast(*[2]Pos, &self.pos)[1];
                }

                fn len(self: *const LocalQueue) usize {
                    const pos = @atomicLoad(usize, &self.pos, .Monotonic);
                    const tail = decodeTail(pos);
                    const head = decodeHead(pos);
                    return tail -% head;
                }

                fn push(self: *LocalQueue, task: *Task, global_queue: *GlobalQueue) void {
                    const pos = @atomicLoad(usize, &self.pos, .Monotonic);
                    const tail = decodeTail(pos);
                    var head = decodeHead(pos);

                    while (true) {
                        if (tail -% head < SIZE) {
                            self.buffer[tail % SIZE] = task;
                            @atomicStore(Pos, self.tailPtr(), tail +% 1, .Release);
                            return;
                        }

                        const batch = SIZE / 2;
                        const new_tail = tail -% batch;
                        if (@cmpxchgWeak(
                            usize,
                            &self.pos,
                            encode(head, tail),
                            encode(head, new_tail),
                            .Monotonic,
                            .Monotonic,
                        )) |new_pos| {
                            head = decodeHead(new_pos);
                            continue;
                        }

                        var list = List{};
                        var index: LocalQueue.Pos = 0;
                        while (index < batch) : (index += 1) {
                            list.push(self.buffer[(new_tail +% index) % SIZE]);
                        }
                        list.push(task);
                        global_queue.push(&list);
                        return;
                    }
                }

                fn pop(self: *LocalQueue) ?*Task {
                    const pos = @atomicLoad(usize, &self.pos, .Monotonic);
                    const tail = decodeTail(pos);
                    var head = decodeHead(pos);

                    while (true) {
                        if (tail -% head == 0)
                            return null;
                        head = @cmpxchgWeak(
                            Pos,
                            self.headPtr(),
                            head,
                            head +% 1,
                            .Monotonic,
                            .Monotonic,
                        ) orelse return self.buffer[head % SIZE];
                    }
                }

                fn stealFrom(self: *LocalQueue, target: *LocalQueue) ?*Task {
                    const tail = self.tailPtr().*;
                    var target_pos = @atomicLoad(usize, &target.pos, .Acquire);

                    while (true) {
                        const target_head = decodeHead(target_pos);
                        const target_tail = decodeTail(target_pos);
                        var batch = switch (target_tail -% target_head) {
                            0 => return null,
                            1 => 1,
                            else => |target_size| target_size / 2,
                        };

                        var index: Pos = 0;
                        var first_task: *Task = undefined;
                        while (index < batch) : (index += 1) {
                            const task = target.buffer[(target_head +% index) % SIZE];
                            if (index == 0) {
                                first_task = task;
                            } else { 
                                self.buffer[(tail +% (index - 1)) % SIZE] = task;
                            }
                        }

                        if (@cmpxchgWeak(
                            usize,
                            &target.pos,
                            target_pos,
                            encode(target_head +% batch, target_tail),
                            .Acquire,
                            .Acquire,
                        )) |new_target_pos| {
                            target_pos = new_target_pos;
                            continue;
                        }

                        batch -= 1;
                        if (batch != 0)
                            @atomicStore(Pos, self.tailPtr(), tail +% batch, .Release);
                        return first_task;
                    }
                }
            };
        };
    };
}