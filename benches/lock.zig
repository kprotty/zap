const std = @import("std");
const zap = @import("zap");

const Task = zap.runtime.Task;
const allocator = std.heap.page_allocator;

const num_iters = 100;
const num_tasks = 500;

pub fn main() !void {
    try (try Task.runAsync(.{ .threads = 2 }, asyncMain, .{}));
}

fn asyncMain() !void {
    const frames = try allocator.alloc(@Frame(runner), num_tasks);
    defer allocator.free(frames);

    var lock = Lock{};
    var counter: u64 = 0;

    for (frames) |*frame, id|
        frame.* = async runner(&lock, &counter, id);

    for (frames) |*frame, id| {
        // std.debug.warn("waiting on {}\n", .{id});
        await frame;
        // std.debug.warn("{} completed\n", .{id});
    }

    // lock.acquireAsync();
    // defer lock.release();

    if (counter != num_tasks * num_iters)
        unreachable; // invalid counter result
}

fn runner(lock: *Lock, counter: *u64, id: usize) void {
    Task.runConcurrentlyAsync();

    var i: usize = num_iters;
    while (i != 0) : (i -= 1) {

        lock.acquireAsync();
        defer lock.release();

        counter.* += 1;
    }

    // std.debug.warn("{} finished on thread {}\n", .{id, std.Thread.getCurrentId()});
}

const Lock = zap.runtime.sync.Lock;

const LockFutex = struct {
    mutex: std.Mutex = std.Mutex{},
    state: usize = UNLOCKED,

    const UNLOCKED = 0;
    const LOCKED = 1;

    const Futex = zap.runtime.sync.AsyncFutex;
    const Condition = zap.core.sync.Condition;

    const Self = @This();
    const Waiter = struct {
        aligned: void align(2),
        next: ?*Waiter,
        tail: *Waiter,
        futex: Futex,
        condition: Condition,
        held: std.Mutex.Held,
        lock: *Self,
    };

    fn acquireAsync(self: *@This()) void {
        const held = self.mutex.acquire();

        if (self.state == UNLOCKED) {
            self.state = LOCKED;
            return held.release();
        }

        var waiter: Waiter = undefined;
        waiter.next = null;
        waiter.futex = Futex{};
        waiter.held = held;
        waiter.lock = self;
        waiter.condition = Condition{ .isMetFn = isAcquireMet };

        const waited = waiter.futex.wait(null, &waiter.condition);
        std.debug.assert(waited);
    }

    fn isAcquireMet(condition: *Condition) bool {
        const waiter = @fieldParentPtr(Waiter, "condition", condition);
        const self = waiter.lock;

        if (if (self.state == LOCKED) @as(?*Waiter, null) else @intToPtr(*Waiter, self.state)) |head| {
            head.tail.next = waiter;
            head.tail = waiter;
        } else {
            self.state = @ptrToInt(waiter);
            waiter.tail = waiter;
        }

        waiter.held.release();
        return false;
    }

    fn release(self: *@This()) void {
        const held = self.mutex.acquire();

        if (self.state == UNLOCKED)
            unreachable; // release when already unlocked

        if (self.state == LOCKED) {
            self.state = UNLOCKED;
            held.release();
            return;
        }

        const waiter = @intToPtr(*Waiter, self.state);
        if (waiter.next) |next| {
            next.tail = waiter.tail;
            self.state = @ptrToInt(next);
        } else {
            self.state = LOCKED;
        }

        held.release();
        waiter.futex.wake();
    }
};

const LockTask = struct {
    mutex: std.Mutex = std.Mutex{},
    state: usize = UNLOCKED,

    const UNLOCKED = 0;
    const LOCKED = 1;

    const Waiter = struct {
        aligned: void align(2),
        next: ?*Waiter,
        tail: *Waiter,
        task: Task,
    };

    fn acquireAsync(self: *@This()) void {
        const held = self.mutex.acquire();

        if (self.state == UNLOCKED) {
            self.state = LOCKED;
            return held.release();
        }

        var waiter: Waiter = undefined;
        waiter.next = null;

        if (if (self.state == LOCKED) @as(?*Waiter, null) else @intToPtr(*Waiter, self.state)) |head| {
            head.tail.next = &waiter;
            head.tail = &waiter;
        } else {
            self.state = @ptrToInt(&waiter);
            waiter.tail = &waiter;
        }

        suspend {
            waiter.task = Task.initAsync(@frame());
            held.release();
        }
    }

    fn release(self: *@This()) void {
        const held = self.mutex.acquire();

        if (self.state == UNLOCKED)
            unreachable; // release when already unlocked

        if (self.state == LOCKED) {
            self.state = UNLOCKED;
            held.release();
            return;
        }

        const waiter = @intToPtr(*Waiter, self.state);
        if (waiter.next) |next| {
            next.tail = waiter.tail;
            self.state = @ptrToInt(next);
        } else {
            self.state = LOCKED;
        }

        held.release();
        waiter.task.schedule();
    }
};