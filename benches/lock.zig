const std = @import("std");
const zap = @import("zap");

const Task = zap.runtime.Task;
const allocator = std.heap.page_allocator;

const num_tasks = 100_00;
const num_iters = 1000;

pub fn main() !void {
    try (try Task.runAsync(.{}, asyncMain, .{}));
}

fn asyncMain() !void {
    const frames = try allocator.alloc(@Frame(locker), num_tasks);
    defer allocator.free(frames);

    var lock = Lock{};
    var counter: u64 = 0;

    for (frames) |*frame| 
        frame.* = async locker(&lock, &counter);
    for (frames) |*frame|
        await frame;

    const count = counter;
    if (count != num_iters * num_tasks)
        std.debug.panic("bad counter: {}\n", .{count});
}

fn locker(lock: *Lock, counter: *u64) void {
    Task.runConcurrentlyAsync();

    var i: usize = num_iters;
    while (i != 0) : (i -= 1) {

        lock.acquireAsync();
        counter.* += 1;
        lock.release();
    }
}

// const Lock = FastLock
const Lock = ParkingLock;

const FastLock = zap.runtime.sync.Lock;
const FairLock = struct {
    lock: FastLock = FastLock{},
    state: usize = UNLOCKED,

    const UNLOCKED: usize = 0;
    const LOCKED: usize = 1;

    const Waiter = struct {
        aligned: void align(2),
        next: ?*Waiter,
        tail: *Waiter,
        task: Task,
    };
    
    fn acquireAsync(self: *@This()) void {
        self.lock.acquire();

        if (self.state == UNLOCKED) {
            self.state = LOCKED;
            self.lock.release();
            return;
        }

        var waiter: Waiter = undefined;
        waiter.next = null;
        if (if (self.state == LOCKED) @as(?*Waiter, null) else @intToPtr(*Waiter, self.state)) |head| {
            head.tail.next = &waiter;
            head.tail = &waiter;
        } else {
            waiter.tail = &waiter;
            self.state = @ptrToInt(&waiter);
        }

        suspend {
            waiter.task = Task.initAsync(@frame());
            self.lock.release();
        }
    }

    fn release(self: *@This()) void {
        self.lock.acquire();

        if (self.state == LOCKED) {
            self.state = UNLOCKED;
            self.lock.release();
            return;
        }

        const waiter = @intToPtr(?*Waiter, self.state) orelse @panic("unlocking an unlocked mutex");
        if (waiter.next) |next| {
            next.tail = waiter.tail;
            self.state = @ptrToInt(next);
        } else {
            self.state = LOCKED;
        }
        
        self.lock.release();
        waiter.task.schedule();
    }
};

const ParkingLock = struct {
    lock: FastLock = FastLock{},
    head: ?*Waiter = null,
    timed_out: u64 = 0,
    rng_seed: u32 = 0,
    state: Atomic(u8) = Atomic(u8).init(UNLOCKED),

    const Atomic = zap.runtime.sync.atomic.Atomic;
    const spinLoopHint = zap.runtime.sync.atomic.spinLoopHint;

    const UNLOCKED: u8 = 0;
    const LOCKED: u8 = 1;
    const PARKED: u8 = 2;

    const Waiter = struct {
        acquired: bool,
        next: ?*Waiter,
        tail: *Waiter,
        task: Task,
    };

    fn tryAcquireX86(self: *@This()) bool {
        return asm volatile(
            "lock btsw $0, %[ptr]"
            : [ret] "={@ccc}" (-> u8),
            : [ptr] "*m" (&self.state)
            : "cc", "memory"
        ) == 0;
    }
    
    fn acquireAsync(self: *@This()) void {
        if (zap.core.is_x86) {
            if (!self.tryAcquireX86())
                self.acquireSlow();
            return;
        }

        if (self.state.tryCompareAndSwap(
            UNLOCKED,
            LOCKED,
            .acquire,
            .relaxed,
        )) |_| {
            self.acquireSlow();
        }
    }

    fn acquireSlow(self: *@This()) void {
        @setCold(true);

        var spin: std.math.Log2Int(usize) = 0;
        var state = self.state.load(.relaxed);

        while (true) {
            if (state & LOCKED == 0) {
                state = self.state.tryCompareAndSwap(
                    state,
                    state | LOCKED,
                    .acquire,
                    .relaxed,
                ) orelse return;
                continue;
            }

            if (state & PARKED == 0) {
                if (spin <= 3) {
                    spin += 1;
                    var i = @as(usize, 1) << spin;
                    while (i != 0) : (i -= 1)
                        spinLoopHint();
                    state = self.state.load(.relaxed);
                    continue;
                }

                if (self.state.tryCompareAndSwap(
                    state,
                    state | PARKED,
                    .relaxed,
                    .relaxed,
                )) |updated| {
                    state = updated;
                    continue;
                }
            }

            defer {
                spin = 0;
                state = self.state.load(.relaxed);
            }

            blk: {
                self.lock.acquire();

                state = self.state.load(.relaxed);
                if (state != (LOCKED | PARKED)) {
                    self.lock.release();
                    break :blk;
                }

                var waiter: Waiter = undefined;
                waiter.acquired = false;
                waiter.next = null;
                if (self.head) |head| {
                    head.tail.next = &waiter;
                    head.tail = &waiter;
                } else {
                    waiter.tail = &waiter;
                    self.head = &waiter;
                }

                suspend {
                    waiter.task = Task.initAsync(@frame());
                    self.lock.release();
                }

                if (waiter.acquired) 
                    return;
            }
        }
    }

    fn release(self: *@This()) void {
        if (self.state.compareAndSwap(
            LOCKED,
            UNLOCKED,
            .release,
            .relaxed,
        )) |_| {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *@This()) void {
        @setCold(true);

        self.lock.acquire();

        var waiter = self.head;
        if (waiter) |w| {
            self.head = w.next;
            if (w.next) |next|
                next.tail = w.tail;
        }

        var is_fair = false;
        if (waiter) |w| {
            var ts = zap.runtime.sync.OsFutex.Timestamp{};
            ts.current();
            const now = ts.nanos;
            if (self.timed_out == 0) {
                is_fair = true;
                self.timed_out = now;
                self.rng_seed = @truncate(u32, @ptrToInt(waiter) >> 8);
            } else if (now > self.timed_out) {
                is_fair = true;
                self.timed_out = now + blk: {
                    var x = self.rng_seed;
                    x ^= x << 13;
                    x ^= x >> 17;
                    x ^= x << 5;
                    self.rng_seed = x;
                    break :blk (x % std.time.ns_per_ms);
                };  
            }
        }

        if (is_fair) {
            waiter.?.acquired = true;
            if (self.head == null)
                self.state.store(LOCKED, .relaxed);
        } else if (self.head != null) {
            self.state.store(PARKED, .release);
        } else {
            self.state.store(UNLOCKED, .release);
        }

        self.lock.release();
        if (waiter) |w|
            w.task.schedule();
    }
};