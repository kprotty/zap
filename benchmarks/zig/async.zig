const std = @import("std");
const ThreadPool = @import("thread_pool");

var thread_pool: ThreadPool = undefined;

/// A zig async version of ThreadPool.Task
pub const Task = struct {
    tp_task: ThreadPool.Task = .{ .callback = resumeFrame },
    frame: anyframe,

    fn resumeFrame(tp_task: *ThreadPool.Task) void {
        const task = @fieldParentPtr(Task, "tp_task", tp_task);
        resume task.frame;
    }

    pub fn schedule(self: *Task) void {
        thread_pool.schedule(&self.tp_task) catch {};
    }

    pub fn reschedule() void {
        var task = Task{ .frame = @frame() };
        suspend {
            task.schedule();
        }
    }
};

pub var allocator: *std.mem.Allocator = undefined;

/// Use HeapAllocator on windows with the Process Heap.
/// Use a Mutex protected ArenaAllocator on Linux when no libc is available.
var heap_allocator: std.heap.HeapAllocator = undefined;
var arena_lock = std.Thread.Mutex{};
var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var arena_thread_safe_allocator = std.mem.Allocator{
    .allocFn = arena_alloc,
    .resizeFn = arena_resize,
};

fn arena_alloc(_: *std.mem.Allocator, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) std.mem.Allocator.Error![]u8 {
    const held = arena_lock.acquire();
    defer held.release();
    return (arena_allocator.allocator.allocFn)(&arena_allocator.allocator, len, ptr_align, len_align, ret_addr);
} 

fn arena_resize(_: *std.mem.Allocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) std.mem.Allocator.Error!usize {
    const held = arena_lock.acquire();
    defer held.release();
    return (arena_allocator.allocator.resizeFn)(&arena_allocator.allocator, buf, buf_align, new_len, len_align, ret_addr);
}

fn ReturnTypeOf(comptime asyncFn: anytype) type {
    return @typeInfo(@TypeOf(asyncFn)).Fn.return_type orelse unreachable; // function is generic
}

/// Starts the global thread pool and executes the asyncFn with args as the entry point.
/// The thread pool is shut down once asyncFn() completes.
pub fn run(comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {
    const Args = @TypeOf(args);
    const Result = ReturnTypeOf(asyncFn);
    const Wrapper = struct {
        fn entry(task: *Task, result: *?Result, fn_args: Args) void {
            suspend {
                task.* = Task{ .frame = @frame() };
            }
            const value = @call(.{}, asyncFn, fn_args);
            result.* = value;
            suspend {
                thread_pool.shutdown();
            }
        }
    };

    // Decide on the allocator. See above
    if (std.builtin.link_libc) {
        allocator = std.heap.c_allocator;
    } else if (std.builtin.target.os.tag == .windows) {
        heap_allocator = @TypeOf(heap_allocator).init();
        heap_allocator.heap_handle = std.os.windows.kernel32.GetProcessHeap() orelse unreachable;
        allocator = &heap_allocator.allocator;
    } else {
        allocator = &arena_thread_safe_allocator;
    }

    // Prepare a Task for the asyncFn
    var task: Task = undefined;
    var result: ?Result = null;
    var frame = async Wrapper.entry(&task, &result, args);

    // Initialize and run the thread pool
    const num_threads = if (std.builtin.single_threaded) 1 else try std.Thread.getCpuCount();
    thread_pool = ThreadPool.init(.{ .max_threads = @intCast(u32, num_threads) });
    thread_pool.schedule(&task.tp_task) catch unreachable;
    thread_pool.deinit();

    // Return the asyncFn result which should be completed
    _ = frame;
    return result orelse error.AsyncFnDeadLocked;
}

pub fn Channel(comptime T: type) type {
    return struct {
        buffer: []T,
        readers: Port = .{},
        writers: Port = .{},

        const Port = struct {
            pos: usize,
            lock: std.Mutex = .{},
        };
    };
}

/// An efficient OneShot channel implementation.
pub fn Oneshot(comptime T: type) type {
    return struct {
        state: Atomic(usize) = Atomic(usize).init(0),

        const Self = @This();
        const Waiter = struct {
            task: Task,
            item: ?T,
        };

        pub fn send(self: *Self, item: T) void {
            var waiter = Waiter{
                .item = item,
                .task = .{ .frame = @frame() },
            };

            suspend {
                const state = self.state.swap(@ptrToInt(&waiter), .AcqRel);
                if (@intToPtr(?*Waiter, state)) |receiver| {
                    receiver.item = item;
                    receiver.task.schedule();
                    resume @frame();
                }
            }
        }

        pub fn recv(self: *@This()) T {
            var waiter = Waiter{
                .item = null,
                .task = .{ .frame = @frame() },
            };

            suspend {
                const state = self.state.swap(@ptrToInt(&waiter), .AcqRel);
                if (@intToPtr(?*Waiter, state)) |sender| {
                    waiter.item = sender.item;
                    sender.task.schedule();
                    resume @frame();
                }
            }

            return waiter.item orelse unreachable;
        }
    };
}
