const std = @import("std");

const List = std.TailQueue(anyframe);
const WaitList = std.TailQueue(*Waiter);
const Waiter = struct {
    event: std.AutoResetEvent = std.AutoResetEvent{},
    next: ?*List.Node = null,
};

var lock = Mutex{};
var is_shutdown = false;
var run_queue = List{};
var idle_queue = WaitList{};

pub fn run(frame: anyframe) !void {
    const allocator = std.heap.c_allocator;
    const extra_threads = (std.Thread.cpuCount() catch 1) - 1;

    const threads = try allocator.alloc(*std.Thread, extra_threads);
    defer allocator.free(threads);

    var spawned: usize = 0;
    defer {
        shutdown();
        for (threads[0..spawned]) |thread|
            thread.wait();
    }

    while (spawned < extra_threads) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn({}, runWorker);
    }

    var frame_node = List.Node{ .data = frame };
    schedule(&frame_node);
    runWorker({});
}

fn runWorker(_: void) void {
    while (true) {
        const held = lock.acquire();

        if (run_queue.pop()) |node| {
            held.release();
            resume node.data;
            continue;
        }

        if (is_shutdown) {
            return held.release();
        }

        var waiter = Waiter{};
        var wait_node = WaitList.Node{ .data = &waiter };
        idle_queue.append(&wait_node);
        held.release();

        waiter.event.wait();
        resume (waiter.next orelse break).data;
    }
}

pub fn reschedule() void {
    suspend {
        var node = List.Node{ .data = @frame() };
        schedule(&node);
    }
}

fn schedule(node: *List.Node) void {
    const held = lock.acquire();

    if (idle_queue.pop()) |waiter_node| {
        held.release();
        const waiter = waiter_node.data;
        waiter.next = node;
        return waiter.event.set();
    }

    run_queue.append(node);
    held.release();
}

pub fn shutdown() void {
    var waiters = blk: {
        const held = lock.acquire();
        defer held.release();

        is_shutdown = true;
        const waiters = idle_queue;
        idle_queue = .{};
        break :blk waiters;
    };

    while (waiters.pop()) |waiter_node| {
        const waiter = waiter_node.data;
        waiter.next = null;
        waiter.event.set();
    }
}

pub const Mutex = if (std.builtin.os.tag != .windows) std.Mutex else struct {
    value: usize = 0,

    pub fn tryAcquire(self: *Mutex) ?Held {
        if (TryAcquireSRWLockExclusive(&self.value) == std.os.windows.TRUE)
            return Held{ .mutex = self };
        return null;
    }

    pub fn acquire(self: *Mutex) Held {
        AcquireSRWLockExclusive(&self.value);
        return Held{ .mutex = self };
    }

    pub const Held = struct {
        mutex: *Mutex,

        pub fn release(self: Held) void {
            ReleaseSRWLockExclusive(&self.mutex.value);
        }
    };

    extern "kernel32" fn TryAcquireSRWLockExclusive(p: *usize) callconv(.Stdcall) std.os.windows.BOOL;
    extern "kernel32" fn AcquireSRWLockExclusive(p: *usize) callconv(.Stdcall) void;
    extern "kernel32" fn ReleaseSRWLockExclusive(p: *usize) callconv(.Stdcall) void;
};