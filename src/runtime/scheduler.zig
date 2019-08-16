const std = @import("std");
const builtin = @import("builtin");

const os = struct {
    pub const thread = @import("thread.zig");
};

pub const Config = struct {
    max_workers: usize,
    max_threads: usize,
    allocator: *std.mem.Allocator,

    pub fn default() Config {
        return Config {
            .max_threads = 10 * 1000,
            .allocator = std.debug.allocator,
            .max_workers = os.thread.cpuCount(),
        };
    }
};

pub fn run(config: Config, comptime function: var, args: ...) anyerror {
    if (@typeInfo(@typeOf(function)).Fn.calling_convention != .Async)
        @compileError("Function to run must be async");

    Task.init(config);
    Thread.init(config);
    Worker.init(config);

    // setup main_task and main_thread on the stack
    const task_size = comptime Task.current.spawn(true, function, args);
    var task_memory: [task_size] align(16) u8 = undefined;
    const mask_task = @ptrCast(*Task, &task_memory[0]);
    _ = main_task.spawn(false, function, args);

    // use only one worker & do not allocate/spawn others
    if (builtin.single_threaded or Worker.max == 1) {
        var main_workers: [1]Worker = undefined;
        Worker.all = main_workers[0..];
        Worker.idle_queue.put(&main_workers[0]);
        main_workers[0].run_queue.put(main_task);
        
    // allocate many workers to start
    } else {
        Monitor.running = false;
        Worker.all = try Worker.allocator.alloc(Worker, Worker.max);
        for (Worker.all) |*worker| Worker.idle_queue.put(worker);
        Worker.idle_queue.top.?.run_queue.put(main_task);
    }

    // run the main_thread (which pops from Worker.idle_queue to run main_task)
    if (Worker.all.len > 1) defer Worker.allocator.free(Worker.all);
    var main_thread: Thread = undefined;
    _ = async main_thread.run();
    return error.None;
}

pub const Monitor = struct {
    pub var running: bool = undefined;

    pub async fn run() void {
        // find Worker
        // find task <- repeat
    }
};

pub const Worker = struct {
    pub var max: usize = undefined;
    pub var all: []Worker = undefined;
    pub var allocator: *std.mem.Allocator = undefined;
    
    pub var global_queue: GlobalRunQueue = undefined;
    pub var idle_queue: AtomicStack(Worker, "link") = undefined;

    link: ?*Worker,
    run_queue: LocalRunQueue,
    state: TaggedPtr(?*Thread, enum { Idle, Running, Syscall }),

    pub fn init(config: Config) void {
        idle_queue.init();
        global_queue.init();
        allocator = config.allocator;
        max = std.math.min(Thread.max, std.math.max(1, config.max_workers));
    }

    pub const GlobalRunQueue = struct {
        pub fn init(self: *@This()) void {

        }
        
        pub fn put(self: *@This(), task: *Task) void {

        }
    };

    pub const LocalRunQueue = struct {
        pub fn init(self: *@This()) void {

        }

        pub fn put(self: *@This(), task: *Task) void {

        }
    };
};

pub const Thread = struct {
    pub var max: usize = undefined;
    pub var stack_size: usize = undefined;

    pub fn init(config: Config) void {
        max = std.math.max(1, config.max_threads);
        stack_size = os.thread.stackSize(Thread.run);
    }

    pub async fn run(self: *Thread) void {

    }
};

pub const Task = struct {
    pub threadlocal var current: *Task = undefined;
    pub var active: usize = undefined;

    link: ?*Task,
    thread: *Thread,
    state: TaggedPtr(?*Task, enum { Running, Completed }),

    pub fn init(config: Config) void {
        active = 0;
    }

    pub fn getFrame(self: *Task) anyframe {
        return @ptrCast(anyframe, &@ptrCast([*]Task, self)[1]);
    }

    pub fn spawn(self: *Task, comptime get_size: bool, comptime function: var, args: ...) usize {
        const Wrapper = struct {
            async fn func(task: *Task, func_args: ...) void {
                _ = @atomicRmw(usize, &active, .Add, 1, .Acquire);
                suspend;
                _ = await function(func_args);
                task.state.store(.Completed, .Monotonic);
                _ = @atomicRmw(usize, &active, .Sub, 1, .Release);
            }
        };

        const frame_size = @frameSize(Wrapper.func);
        if (get_size) return frame_size;

        std.mem.secureZero(Task, @ptrCast([*]Task, self)[0..1]);
        const frame_memory = @ptrCast([*]u8, self.getFrame())[0..frame_size];
        _ = @asyncCall(frame_memory, {}, Wrapper.func, args);
        return 0;
    }
};

fn TaggedPtr(comptime Ptr: type, comptime Tag: type) type {
    comptime std.debug.assert(@typeId(Tag) == builtin.TypeId.Enum);
    comptime std.debug.assert(@typeInfo(@TagType(Tag)).Int.bits <= @alignOf(Ptr) * 8);

    return struct {
        value: usize,

        pub fn new(ptr: Ptr, tag: Tag) @This() {
            return (@This() { .value = @ptrToInt(ptr) }).tagged(tag);
        }

        pub fn tagged(self: @This(), tag: Tag) @This() {
            return @This() { .value = @ptrToInt(self.getPtr()) | usize(@enumToInt(tag)) };
        }

        pub fn getPtr(self: @This()) Ptr {
            return @intToPtr(Ptr, self.value & ~usize(~@TagType(Tag)(0)));
        }

        pub fn getTag(self: @This()) Tag {
            return @intToEnum(Tag, @truncate(@TagType(Tag), self.value));
        }
    };
}

fn AtomicStack(comptime Node: type, comptime Field: []const u8) type {
    const field_type = @typeInfo(@typeInfo(@typeOf(@field(Node(undefined), Field))).Optional.child).Pointer;
    comptime std.debug.assert(field_type.size == .One and field_type.child == Node);

    return struct {
        top: ?*Node,
        count: usize,

        pub fn init(self: *@This()) void {
            self.count = 0;
            self.top = null;
        }

        pub fn getTop(self: *@This()) *Node {
            return @atomicLoad(?*Node, &self.top, .Monotonic).?;
        }

        pub fn put(self: *@This(), node: *Node) void {
            _ = @atomicRmw(usize, &self.count, .Add, 1, .Acquire);
            @field(node, Field) = @atomicLoad(?*Node, &self.top, .Monotonic);
            while (@cmpxchgWeak(?*Node, &self.top, @field(node, Field), node, .Acquire, .Monotonic)) |new_top|
                @field(node, Field) = new_top;
        }

        pub fn get(self: *@This()) ?*Node {
            var top = @atomicLoad(?*Node, &self.top, .Monotonic);
            while (top != null) {
                if (@cmpxchgWeak(?*Node, &self.top, @field(top.?, Field), .Release, .Monotonic)) |new_top| {
                    top = new_top;
                } else {
                    _ = @atomicRmw(usize, &self.count, .Sub, 1, .Release);
                    break;
                };
            }
            return top;
        }
    }
}