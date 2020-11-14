const std = @import("std");
const ziggo = @import("./ziggo.zig");

fn ReturnTypeOf(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).Fn.return_type.?;
}

pub fn run(comptime asyncFn: anytype, args: anytype) ReturnTypeOf(asyncFn) {
    const Args = @TypeOf(args);
    const Decorator = struct {
        fn entry(frame_ptr: *anyframe, result_ptr: *?ReturnTypeOf(asyncFn), fn_args: Args) void {
            suspend frame_ptr.* = @frame();
            const result = @call(.{}, asyncFn, fn_args);
            suspend {
                result_ptr.* = result;
                Scheduler.instance.?.shutdown();
            }
        }
    };

    var frame_ptr: anyframe = undefined;
    var result: ?ReturnTypeOf(asyncFn) = null;
    var frame = async Decorator.entry(&frame_ptr, &result, args);

    var scheduler: Scheduler = undefined;
    scheduler.init();
    scheduler.run_queue.push(frame_ptr);
    scheduler.run();
    scheduler.deinit();

    return result orelse unreachable;
}

pub fn schedule(frame: anyframe) void {
    Scheduler.instance.?.schedule(frame);
}

pub fn yield() void {
    suspend schedule(@frame());
}

pub fn spawn(comptime asyncFn: anytype, args: anytype) void {
    const Args = @TypeOf(args);
    const Decorator = struct {
        fn entry(allocator: *std.mem.Allocator, fn_args: Args) void {
            yield();
            _ = @call(.{}, asyncFn, fn_args);
            suspend allocator.destroy(@frame());
        }
    };

    const allocator = Heap.getAllocator();
    var frame = allocator.create(@Frame(Decorator.entry)) catch unreachable;
    frame.* = async Decorator.entry(allocator, args);
}

const Scheduler = struct {
    is_shutdown: bool,
    run_queue: RunQueue,
    idle_queue: IdleQueue,
    threads: std.ArrayList(*std.Thread),

    var instance: ?*Scheduler = null;

    fn init(self: *Scheduler) void {
        const allocator = Heap.getAllocator();

        instance = self;
        self.* = Scheduler{
            .is_shutdown = false,
            .run_queue = RunQueue.init(allocator),
            .idle_queue = IdleQueue.init(allocator),
            .threads = std.ArrayList(*std.Thread).init(allocator),
        };

        if (!std.builtin.single_threaded) {
            var threads = std.math.max(1, std.Thread.cpuCount() catch 1) - 1;
            while (threads > 0) : (threads -= 1) {
                const thread = std.Thread.spawn(self, Scheduler.run) catch unreachable;
                self.threads.append(thread) catch unreachable;
            }
        }
    }

    fn deinit(self: *Scheduler) void {
        while (self.threads.popOrNull()) |thread|
            thread.wait();
        self.idle_queue.deinit();
        self.run_queue.deinit();
        self.* = undefined;
    }

    fn schedule(self: *Scheduler, frame: anyframe) void {
        self.run_queue.push(frame);
        self.idle_queue.notify(1);
    }

    fn run(self: *Scheduler) void {
        while (!@atomicLoad(bool, &self.is_shutdown, .SeqCst)) {
            if (self.run_queue.pop()) |frame| {
                resume frame;
            } else {
                self.idle_queue.wait();
            }
        }
    }

    fn shutdown(self: *Scheduler) void {
        @atomicStore(bool, &self.is_shutdown, true, .SeqCst);
        self.idle_queue.notify(self.threads.items.len + 1);
    }

    const RunQueue = struct {
        lock: Lock = Lock{},
        queue: std.ArrayList(anyframe),

        fn init(allocator: *std.mem.Allocator) RunQueue {
            return RunQueue{
                .queue = std.ArrayList(anyframe).init(allocator),
            };
        }

        fn deinit(self: *RunQueue) void {
            while (self.queue.popOrNull()) |frame|
                resume frame;
        }

        fn push(self: *RunQueue, frame: anyframe) void {
            self.lock.acquire();
            defer self.lock.release();
            self.queue.append(frame) catch unreachable;
        }

        fn pop(self: *RunQueue) ?anyframe {
            self.lock.acquire();
            defer self.lock.release();
            return self.queue.popOrNull();
        }
    };

    const IdleQueue = struct {
        lock: Lock = Lock{},
        counter: usize = 0,
        queue: std.ArrayList(*std.AutoResetEvent),

        fn init(allocator: *std.mem.Allocator) IdleQueue {
            return IdleQueue{
                .queue = std.ArrayList(*std.AutoResetEvent).init(allocator),
            };
        }

        fn deinit(self: *IdleQueue) void {
            self.* = undefined;
        }

        fn wait(self: *IdleQueue) void {
            self.lock.acquire();

            while (true) {
                if (self.counter > 0) {
                    self.counter -= 1;
                    const waiter = self.queue.popOrNull();
                    self.lock.release();
                    if (waiter) |event|
                        event.set();
                    return;
                }

                var event = std.AutoResetEvent{};
                self.queue.append(&event) catch unreachable;
                self.lock.release();
                event.wait();
                self.lock.acquire();
            }
        }

        fn notify(self: *IdleQueue, count: usize) void {
            self.lock.acquire();

            self.counter += count;
            const waiter = self.queue.popOrNull();
            self.lock.release();
            if (waiter) |event|
                event.set();
        }
    };
};

pub const sync = struct {
    pub const WaitGroup = struct {
        lock: Lock = Lock{},
        count: usize,
        waiter: ?anyframe = null,

        pub fn init(count: usize) WaitGroup {
            return WaitGroup{ .count = count };
        }

        pub fn done(self: *WaitGroup) void {
            const waiter = blk: {
                self.lock.acquire();
                defer self.lock.release();

                self.count -= 1;
                if (self.count != 0)
                    return;
                break :blk self.waiter;
            };

            if (waiter) |frame|
                schedule(frame);
        }

        pub fn wait(self: *WaitGroup) void {
            self.lock.acquire();

            if (self.count == 0)
                return self.lock.release();

            suspend {
                self.waiter = @frame();
                self.lock.release();
            }
        }
    };
};

const Lock = struct {
    mutex: std.Mutex = std.Mutex{},

    pub fn acquire(self: *Lock) void {
        _ = self.mutex.acquire();
    }

    pub fn release(self: *Lock) void {
        (std.Mutex.Held{ .mutex = &self.mutex }).release();
    }
};

const Heap = struct {
    var init_lock = Lock{};
    var is_init: bool = false;
    var global_heap: std.heap.GeneralPurposeAllocator(.{}) = undefined;

    fn getAllocator() *std.mem.Allocator {
        if (@atomicLoad(bool, &is_init, .SeqCst))
            return &global_heap.allocator;

        init_lock.acquire();
        defer init_lock.release();

        if (@atomicLoad(bool, &is_init, .SeqCst))
            return &global_heap.allocator;

        global_heap = std.heap.GeneralPurposeAllocator(.{}){};
        @atomicStore(bool, &is_init, true, .SeqCst);

        return &global_heap.allocator;
    }
};