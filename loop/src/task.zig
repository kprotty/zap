const std = @import("std");
const system = @import("./system/system.zig");
const TaskPool = @import("./core/pool.zig").Pool(Task.Scheduler.Platform);

pub const Task = struct {
    pub const Pool = TaskPool;
    pub const Scheduler = TaskScheduler;
    pub const AutoResetEvent = TaskAutoResetEvent;

    frame: anyframe,
    pool_task: Pool.Task,

    pub fn init(frame: anyframe) Task {
        return Task{
            .frame = frame,
            .pool_task = Pool.Task{ .callback = &ResumeContext.callback },
        };
    }

    const ResumeContext = struct {
        worker: *Pool.Worker,

        pub const Error = error{
            NotRunningInPool,
        };

        threadlocal var current: ?*ResumeContext = null;

        fn getCurrent() Error!*ResumeContext {
            return current orelse return Error.NotRunningInPool;
        }

        fn callback(pool_task: *Pool.Task, worker: *Pool.Worker) callconv(.C) void {
            var ctx = ResumeContext{
                .worker = worker,
            };

            const old_ctx = current;
            current = &ctx;
            defer current = old_ctx;

            const frame = @fieldParentPtr(Task, "pool_task", pool_task).frame;
            resume frame;
        }
    };
        
    pub fn yield() void {
        var task = Task.init(@frame());
        suspend {
            var list = Pool.Task.List.from(&task.pool_task);
            Task.schedule(&list) catch resume @frame();
        }
    }

    pub fn schedule(list: *Pool.Task.List) ResumeContext.Error!void {
        const ctx = try ResumeContext.getCurrent();
        switch (list.len) {
            0 => return,
            1 => ctx.worker.schedule(list.pop().?),
            else => ctx.worker.pool.schedule(list),
        }
    }
};

const TaskAutoResetEvent = struct {
    const EMPTY = std.math.minInt(usize);
    const NOTIFIED = std.math.maxInt(usize);

    state: usize = EMPTY,

    pub fn init(self: *TaskAutoResetEvent) void {
        self.* = TaskAutoResetEvent{};
    }

    pub fn deinit(self: *TaskAutoResetEvent) void {
        defer self.* = undefined;

        if (std.debug.runtime_safety) {
            const state = @atomicLoad(usize, &self.state, .Monotonic);
            if (!(state == EMPTY or state == NOTIFIED))
                std.debug.panic("TaskAutoResetEvent.deinit() with pending waiter\n", .{});
        }
    }

    pub fn set(self: *TaskAutoResetEvent, direct_yield: bool) void {
        var state = @atomicLoad(usize, &self.state, .Acquire);

        if (state == EMPTY) {
            state = @cmpxchgStrong(
                usize,
                &self.state,
                EMPTY,
                NOTIFIED,
                .Release,
                .Acquire,
            ) orelse return;
        }

        if (state == NOTIFIED)
            return;

        @atomicStore(usize, &self.state, EMPTY, .Release);
        
        // TODO: support Task.yieldTo() for direct_yield
        // currently generates this error atm: 
        //
        // broken LLVM module found: Instruction does not dominate all uses!
        //   %24 = load i1, i1* %4, align 1, !dbg !18700
        //   %23 = phi i1 [ %24, %PtrCastOk ], [ %25, %BoolAndTrue ], !dbg !18700
        // Instruction does not dominate all uses!
        //   %25 = load i1, i1* %7, align 1, !dbg !18700
        //   %23 = phi i1 [ %24, %PtrCastOk ], [ %25, %BoolAndTrue ], !dbg !18700
        const task = @intToPtr(*TaskPool.Task, state);
        var list = TaskPool.Task.List.from(task);
        Task.schedule(&list) catch unreachable;
    }

    pub fn wait(self: *TaskAutoResetEvent) void {
        var state = @atomicLoad(usize, &self.state, .Acquire);

        if (state == EMPTY) {
            var task = Task.init(@frame());
            suspend {
                if (@cmpxchgStrong(
                    usize,
                    &self.state,
                    EMPTY,
                    @ptrToInt(&task.pool_task),
                    .Release,
                    .Acquire,
                )) |new_state| {
                    state = new_state;
                    resume @frame();
                }
            }
            if (state == EMPTY)
                return;
        }

        std.debug.assert(state == NOTIFIED);
        @atomicStore(usize, &self.state, EMPTY, .Monotonic);
    }

    pub fn tryWaitUntil(self: *TaskAutoResetEvent, deadline: u64) error{TimedOut}!void {
        @compileError("TODO: timers");
    }

    pub fn nanotime() u64 {
        return system.AutoResetEvent.nanotime();
    }

    pub fn yield(contended: bool, iteration: usize) bool {
        // Its more efficient to suspend the async frame than to spin on the cpu.
        return false;
    }
};

const TaskScheduler = struct {
    pub const Options = struct {
        pin_core_threads: bool = false,
        max_core_threads: ?usize = null,
        max_io_threads: ?usize = null,
        max_stack_size: ?usize = 16 * 1024 * 1024,
    };

    pub const Worker = extern struct {
        pool_worker: TaskPool.Worker,
        pin_cpu: usize,

        pub fn run(self: *Worker) void {
            return self.pool_worker.run();
        }
    };

    pub const Platform = struct {
        max_stack_size: ?usize,

        pub const LOCAL_QUEUE_SIZE = 256;

        pub const CACHE_LINE = switch (std.builtin.arch) {
            .x86_64 => 64 * 2,
            else => 64,
        };

        pub const AutoResetEvent = system.AutoResetEvent;

        pub fn pollWorker(
            self: *Platform,
            pool_worker: *TaskPool.Worker,
            is_last_resort: bool,
            iteration: usize,
            list: *TaskPool.Task.List,
        ) void {
            return;
        }

        pub fn runWorker(
            self: *Platform,
            is_main_thread: bool,
            pool_worker: *TaskPool.Worker,
        ) bool {
            system.Thread.spawn(
                @fieldParentPtr(Worker, "pool_worker", pool_worker),
                is_main_thread,
                self.max_stack_size,
            ) catch return false;
            return true;
        }
    };

    pub const RunError = RunTaskError || error{
        DidNotComplete,
    };

    pub fn run(options: Options, comptime entryFn: var, args: var) RunError!@TypeOf(entryFn).ReturnType {
        const Result = @TypeOf(entryFn).ReturnType;
        const Wrapper = struct {
            fn capture(comptime func: var, fn_args: var, task: *Task, result: *?Result) void {
                task.* = Task.init(@frame());
                suspend;
                result.* = @call(.{}, func, fn_args);
            }
        };

        var task: Task = undefined;
        var result: ?Result = null;
        var frame = async Wrapper.capture(entryFn, args, &task, &result);
        
        try runTask(options, &task.pool_task);
        return result orelse error.DidNotComplete;
    }

    pub const RunTaskError = error{
        OutOfMemory,
    };

    pub fn runTask(options: Options, pool_task: *TaskPool.Task) RunTaskError!void {
        const num_workers = 
            if (std.builtin.single_threaded) 1
            else std.math.max(1, options.max_core_threads orelse (std.Thread.cpuCount() catch 1));

        var platform = Platform{ .max_stack_size = options.max_stack_size };
        if (num_workers == 1) {
            var worker = Worker{
                .pool_worker = undefined,
                .pin_cpu = if (options.pin_core_threads) 0 else system.Thread.INVALID_PIN_CPU,
            };
            const worker_ptrs = ([_]*TaskPool.Worker{ &worker.pool_worker })[0..];
            TaskPool.run(&platform, worker_ptrs, pool_task);

        } else {
            var alloc_size: usize = 0;
            const worker_ptr_offset = alloc_size;
            alloc_size = std.mem.alignForward(@sizeOf(*TaskPool.Worker) * num_workers, @alignOf(Worker));
            const worker_offset = alloc_size;
            alloc_size += @sizeOf(Worker) * num_workers;

            const allocator = std.heap.page_allocator;
            const memory = allocator.allocWithOptions(u8, alloc_size, @alignOf(Worker), null) catch return error.OutOfMemory;
            defer allocator.free(memory);

            const PoolWorkerPtr = [*]*TaskPool.Worker;
            const worker_ptrs = @ptrCast(PoolWorkerPtr, @alignCast(@alignOf(PoolWorkerPtr), &memory[worker_ptr_offset]))[0..num_workers];
            const workers = @ptrCast([*]Worker, @alignCast(@alignOf(Worker), &memory[worker_offset]))[0..num_workers];
            for (worker_ptrs) |*worker_ptr, index| {
                worker_ptr.* = &workers[index].pool_worker;
                workers[index].pin_cpu = if (options.pin_core_threads) index else system.Thread.INVALID_PIN_CPU;
            }

            TaskPool.run(&platform, worker_ptrs, pool_task);
        }
    }
};
