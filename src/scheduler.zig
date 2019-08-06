const std = @import("std");
const builtin = @import("builtin");

pub fn run(max_workers: usize, comptime function: var, args: ...) !void {
    var main_task: Task = undefined;
    var main_thread: Thread = undefined;
    var main_worker: Worker = undefined;

    Worker.all.init();
    Worker.all.push(&main_worker);
    Worker.idle.init();
    Worker.idle.push(&main_worker);

    main_worker.init()
    main_worker.spawn(&main_task, function, args);
    main_thread.run();
}

pub const Worker = struct {
    pub var max: usize = undefined;
    pub var all: SharedQueue(Worker, "next") = undefined;
    pub var idle: SharedQueue(Worker, "link") = undefined;

    status: Status,
    next: ?*Worker,
    link: ?*Worker,

    pub fn init(self: *Worker) void {

    }

    pub const Status = enum {
        Idle,
        Running,
        Syscall,
    };
};

pub const Thread = struct {
    worker: *Worker,
    handle: ?*std.Thread,
};

pub const Task = struct {
    pub threadlocal var current: *Task = undefined;

    pub var active: usize = 0;
    pub var global = SharedQueue(Task, "next").new();

    next: ?*Task,
    status: Status,
    handle: promise,
    thread: *Thread,

    pub const Status = enum {
        Runnable,
        Running,
        Completed,
    };

    pub fn spawn(task: *Task, allocator: *std.mem.Allocator, comptime function: var, args: ...) !void {
        const TaskWrapper = struct {
            async fn func(task_ref: *Task, func_args: ...) void {
                suspend {
                    task_ref.handle = @handle();
                    task_ref.status = .Runnable;
                }
                _ = await (async function(func_args) catch unreachable);
                task_ref.status = .Completed;
            }
        };
        _ = try async<allocator> TaskWrapper.func(task, args);
    }
};

fn SharedQueue(comptime Node: type, comptime Field: []const u8) type {
    const Queue = struct {
        head: *Node,
        tail: *Node,
        stub: ?*Node,

        pub fn init(self: *Queue) void {
            self.head = @fieldParentPtr(Node, Field, &self.stub);
            self.tail = self.head;
            self.stub = null;
        }

        pub fn push(self: *Queue, node: *Node) void {
            @fence(.Release);
            const prev = @atomicRmw(*Node, &self.head, .Xchg, node, .Monotonic);
            @field(prev, Field) = node; // TODO: replace with atomicStore() https://github.com/ziglang/zig/issues/2995
        }

        pub fn pop(self: *Queue) ?*Node {
            var tail = @atomicLoad(*Node, &self.tail, .Unordered);
            while (true) {
                const next = @atomicLoad(?*Node, &@field(tail, Field), .Unordered) orelse return null;
                if (@cmpxchgWeak(*Node, &self.tail, tail, next, .Monotonic, .Monotonic)) |new_tail| {
                    tail = new_tail;
                    continue;
                }
                @fence(.Acquire);
                return next;
            }
        }

        fn isValidNode() bool {
            const field = if (@hasField(Node, Field)) @typeOf(@field(Node(undefined), Field)) else return false;
            const ftype = if (@typeId(field) == .Optional) @typeInfo(field).Optional.child else return false;
            const ptype = if (@typeId(ftype) == .Pointer) @typeInfo(ftype).Pointer else return false;
            return ptype.size == .One and ptype.child == Node;
        }
    };

    comptime std.debug.assert(Queue.isValidNode());
    return Queue;
}


