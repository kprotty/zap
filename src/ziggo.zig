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
    scheduler.run_queue.append(frame_ptr) catch unreachable;
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
    lock: Lock,
    is_shutdown: bool,
    threads: std.ArrayList(*std.Thread),
    run_queue: std.ArrayList(anyframe),
    idle_queue: std.ArrayList(*std.AutoResetEvent),

    var instance: ?*Scheduler = null;

    fn init(self: *Scheduler) void {
        const allocator = Heap.getAllocator();

        instance = self;
        self.* = Scheduler{
            .lock = Lock{},
            .is_shutdown = false,
            .threads = std.ArrayList(*std.Thread).init(allocator),
            .run_queue = std.ArrayList(anyframe).init(allocator),
            .idle_queue = std.ArrayList(*std.AutoResetEvent).init(allocator),
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
        while (self.run_queue.popOrNull()) |frame|
            resume frame;
        self.* = undefined;
    }

    fn schedule(self: *Scheduler, frame: anyframe) void {
        const event = blk: {
            self.lock.acquire();
            defer self.lock.release();

            if (self.is_shutdown)
                return;

            self.run_queue.append(frame) catch unreachable;
            break :blk self.idle_queue.popOrNull();
        };

        if (event) |auto_reset_event|
            auto_reset_event.set();
    }

    fn run(self: *Scheduler) void {
        while (true) {
            self.lock.acquire();

            if (self.is_shutdown) {
                self.lock.release();
                return;
            }

            if (self.run_queue.popOrNull()) |frame| {
                self.lock.release();
                resume frame;
                continue;
            }

            var event = std.AutoResetEvent{};
            self.idle_queue.append(&event) catch unreachable;
            self.lock.release();
            event.wait();
        }
    }

    fn shutdown(self: *Scheduler) void {
        var idle_queue = blk: {
            self.lock.acquire();
            defer self.lock.release();

            if (self.is_shutdown)
                return;

            self.is_shutdown = true;
            break :blk &self.idle_queue;
        };

        while (idle_queue.popOrNull()) |event|
            event.set();
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