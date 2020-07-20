const std = @import("std");
const system = @import("./system.zig");
const scheduler = @import("./scheduler.zig");

const assert = std.debug.assert;

const Link = scheduler.Link;
const Builder = scheduler.Builder;
const Runnable = scheduler.Runnable;

pub const Task = struct {
    runnable: Runnable,
    frame: anyframe,

    pub const Priority = Runnable.Priority;

    pub const Context = struct {
        next: ?*Runnable,
        runnable_context: Runnable.Context,

        threadlocal var current: ?*Context = null;

        fn @"resume"(
            noalias runnable: *Runnable,
            noalias runnable_context: Runnable.Context,
        ) callconv(.C) ?*Runnable {
            var context = Context{
                .next = null,
                .runnable_context = runnable_context,
            };
            
            const old_context = Context.current;
            Context.current = &context;
            defer Context.current = old_context;

            const task = Task.fromRunnable(runnable);
            resume task.frame;
            
            return context.next;
        }

        pub fn initTask(self: Context, frame: anyframe, priority: Priority) Task {
            return Task{
                .runnable = Runnable.init(priority, Context.@"resume"),
                .frame = frame,
            };
        }

        pub fn schedule(self: Context, runnable: *Runnable) void {
            return self.scheduleMany(Link.Queue.fromLink(runnable.getLink()));
        }

        pub fn scheduleMany(self: Context, queue: Link.Queue) void {
            return self.runnable_context.schedule(.Local, queue);
        }

        pub fn yield(self: Context, priority: Priority) void {
            var task = self.initTask(@frame(), priority);
            suspend {
                self.schedule(task.getRunnable());
            }
        }

        // TODO: Currently breaks with
        //      broken LLVM module found: Instruction does not dominate all uses!
        //        %32 = load i1, i1* %4, align 1, !dbg !14838
        //        %31 = phi i1 [ %32, %Entry ], [ %33, %BoolAndTrue ], !dbg !14838
        //      Instruction does not dominate all uses!
        //        %33 = load i1, i1* %7, align 1, !dbg !14838
        //        %31 = phi i1 [ %32, %Entry ], [ %33, %BoolAndTrue ], !dbg !14838
        //
        // pub fn yieldInto(self: *Context, priority: Priority, runnable: *Runnable) void {
        //    var task = self.initTask(@frame(), priority);
        //    suspend {
        //        self.schedule(task.getRunnable());
        //        self.next = runnable;
        //    }
        // }
    };

    pub fn fromRunnable(runnable: *Runnable) *Task {
        return @fieldParentPtr(Task, "runnable", runnable);
    }

    pub fn getRunnable(self: *Task) *Runnable {
        return &self.runnable;
    }

    pub fn getContext() ?*Context {
        return Context.current;
    }

    pub const RunOptions = Builder;
    
    pub const RunError = Builder.RunError || error{
        DidNotComplete,
    };

    pub fn run(
        options: RunOptions,
        comptime entryFn: var,
        args: var,
    ) RunError!@TypeOf(entryFn).ReturnType {
        const ReturnType = @TypeOf(entryFn).ReturnType;
        const Wrapper = struct {
            fn entry(
                comptime func: var,
                func_args: var,
                task_ptr: *Task,
                result_ptr: *?ReturnType,
            ) void {
                task_ptr.* = @as(Context, undefined).initTask(@frame(), .Normal);
                suspend;
                const result = @call(.{}, func, func_args);
                result_ptr.* = result;
            }
        };

        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.entry(entryFn, args, &task, &result);

        try options.run(task.getRunnable());
        return result orelse RunError.DidNotComplete;
    }

    pub const AutoResetEvent = struct {
        const EMPTY = 0x0;
        const NOTIFIED = 0x1;

        state: usize = EMPTY,

        pub fn init(self: *AutoResetEvent) void {
            self.* = AutoResetEvent{};
        }

        pub fn deinit(self: *AutoResetEvent) void {
            const state = @atomicLoad(usize, &self.state, .Monotonic);
            assert(state == EMPTY or state == NOTIFIED);
        }

        pub fn notify(self: *AutoResetEvent) void {
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
            
            const runnable = @intToPtr(*Runnable, state);
            const context = getContext() orelse unreachable;
            context.schedule(runnable);
        }

        pub fn wait(self: *AutoResetEvent) void {
            var state = @atomicLoad(usize, &self.state, .Acquire);

            if (state == EMPTY) {
                const context = getContext() orelse unreachable;
                var task = context.initTask(@frame(), .Normal);
                suspend {
                    if (@cmpxchgStrong(
                        usize,
                        &self.state,
                        EMPTY,
                        @ptrToInt(task.getRunnable()),
                        .Release,
                        .Acquire,
                    )) |new_state| {
                        state = new_state;
                        resume @frame();
                    } else {
                    }
                }
                if (state == EMPTY)
                    return;
            }

            if (state != NOTIFIED)
                std.debug.panic("bad state = {}\n", .{state});
            @atomicStore(usize, &self.state, EMPTY, .Monotonic);
        }

        pub fn tryWaitUntil(self: *AutoResetEvent, deadline: u64) error{TimedOut}!void {
            @compileError("TODO: timers");
        }

        pub fn nanotime() u64 {
            return system.AutoResetEvent.nanotime();
        }
    };
};