const std = @import("std");
const Lock = @import("./lock.zig").Lock;

pub const Scheduler = struct {
    is_shutdown: bool,
    run_queue: RunQueue,
    idle_queue: IdleQueue,
    threads: std.ArrayList(*std.Thread),
    allocator: *std.mem.Allocator,

    pub var instance: ?*Scheduler = null;

    pub fn init(self: *Scheduler, allocator: *std.mem.Allocator) void {
        instance = self;
        self.* = Scheduler{
            .is_shutdown = false,
            .run_queue = RunQueue.init(allocator),
            .idle_queue = IdleQueue.init(allocator),
            .threads = std.ArrayList(*std.Thread).init(allocator),
            .allocator = allocator,
        };

        if (!std.builtin.single_threaded) {
            var threads = std.math.max(1, std.Thread.cpuCount() catch 1) - 1;
            while (threads > 0) : (threads -= 1) {
                const thread = std.Thread.spawn(self, Scheduler.run) catch unreachable;
                self.threads.append(thread) catch unreachable;
            }
        }
    }

    pub fn deinit(self: *Scheduler) void {
        while (self.threads.popOrNull()) |thread|
            thread.wait();
        self.idle_queue.deinit();
        self.run_queue.deinit();
        self.* = undefined;
    }

    pub fn start(self: *Scheduler, frame: anyframe) void {
        self.run_queue.push(frame);
        self.run();
    }

    pub fn schedule(self: *Scheduler, frame: anyframe) void {
        self.run_queue.push(frame);
        self.idle_queue.notify(1);
    }

    pub fn run(self: *Scheduler) void {
        while (!@atomicLoad(bool, &self.is_shutdown, .SeqCst)) {
            if (self.run_queue.pop()) |frame| {
                resume frame;
            } else {
                self.idle_queue.wait();
            }
        }
    }

    pub fn shutdown(self: *Scheduler) void {
        @atomicStore(bool, &self.is_shutdown, true, .SeqCst);
        self.idle_queue.notify(self.threads.items.len + 1);
    }
};

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
        var next_waiter: ?*std.AutoResetEvent = undefined;
        defer if (next_waiter) |event|
            event.set();

        while (true) {
            self.lock.acquire();

            if (self.counter > 0) {
                self.counter -= 1;
                next_waiter = self.queue.popOrNull();
                self.lock.release();
                break;
            }

            var waiter = std.AutoResetEvent{};
            self.queue.append(&waiter) catch unreachable;
            self.lock.release();
            waiter.wait();
        }
    }

    fn notify(self: *IdleQueue, count: usize) void {
        if (count == 0)
            return;

        const waiter = blk: {
            self.lock.acquire();
            defer self.lock.release();

            self.counter += count;
            break :blk self.queue.popOrNull();
        };

        if (waiter) |event|
            event.set();
    }
};