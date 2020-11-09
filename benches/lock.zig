const Z = @import("./z.zig");

const num_tasks = 100_00;
const num_iters = 1000;

pub fn main() !void {
    try Z.Task.runAsync(.{}, asyncMain, .{});
}

fn asyncMain() void {
    var lock = Lock{};
    var counter: u64 = 0;
    var wg = Z.WaitGroup.init(num_tasks);

    var i: usize = num_tasks;
    while (i > 0) : (i -= 1)
        Z.spawn(locker, .{&lock, &wg, &counter});

    wg.wait();

    const count = counter;
    if (count != num_iters * num_tasks)
        @panic("bad counter");
}

fn locker(lock: *Lock, wg: *Z.WaitGroup, counter: *u64) void {
    defer wg.done();

    var i: usize = num_iters;
    while (i != 0) : (i -= 1) {

        lock.acquireAsync();
        counter.* += 1;
        lock.release();
    }
}

// const Lock = FastLock
const Lock = TestFairLock;

const FastLockAsync = struct {
    lock: FastLock = FastLock{},

    fn acquireAsync(self: *FastLockAsync) void {
        self.lock.acquire();
    }

    fn release(self: *FastLockAsync) void {
        self.lock.release();
    }
};

const MutexLockAsync = struct {
    lock: std.Mutex = std.Mutex{},

    fn acquireAsync(self: *@This()) void {
        _ = self.lock.acquire();
    }

    fn release(self: *@This()) void {
        (std.Mutex.Held{ .mutex = &self.lock }).release();
    }
};

const FastLock = Z.zap.runtime.sync.Lock;
const FairLock = struct {
    lock: FastLock = FastLock{},
    state: usize = UNLOCKED,

    const UNLOCKED: usize = 0;
    const LOCKED: usize = 1;

    const Waiter = struct {
        aligned: void align(2),
        next: ?*Waiter,
        tail: *Waiter,
        task: Z.Task,
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
            waiter.task = Z.Task.initAsync(@frame());
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
        Z.Task.Batch.from(&waiter.task).schedule(.{ .use_lifo = true });
    }
};

const ParkingLock = struct {
    lock: FastLock = FastLock{},
    head: ?*Waiter = null,
    timed_out: u64 = 0,
    rng_seed: u32 = 0,
    state: Atomic(u8) = Atomic(u8).init(UNLOCKED),

    const Atomic = Z.zap.runtime.sync.atomic.Atomic;
    const spinLoopHint = Z.zap.runtime.sync.atomic.spinLoopHint;

    const UNLOCKED: u8 = 0;
    const LOCKED: u8 = 1;
    const PARKED: u8 = 2;

    const Waiter = struct {
        acquired: bool,
        next: ?*Waiter,
        tail: *Waiter,
        task: Z.Task,
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
        if (Z.zap.core.is_x86) {
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

        var spin: Z.std.math.Log2Int(usize) = 0;
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
                self.lock.acquireAsync();

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
                    waiter.task = Z.Task.initAsync(@frame());
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

        self.lock.acquireAsync();

        var waiter = self.head;
        if (waiter) |w| {
            self.head = w.next;
            if (w.next) |next|
                next.tail = w.tail;
        }

        var is_fair = false;
        if (!is_fair) {
            if (waiter) |w| {
                var ts = Z.zap.runtime.sync.OsFutex.Timestamp{};
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
                        break :blk (x % Z.std.time.ns_per_ms);
                    };  
                }
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
        if (waiter) |w| {
            Z.Task.Batch.from(&w.task).schedule(.{ .use_lifo = true });
        }
    }
};

const TestFairLock = struct {
    state: usize = UNLOCKED,

    const UNLOCKED: usize = 0;
    const LOCKED: usize = 1;
    const WAITING: usize = ~LOCKED;

    const is_x86 = Z.zap.core.is_x86;
    const Waiter = struct {
        prev: ?*Waiter align(~WAITING + 1),
        next: ?*Waiter,
        tail: ?*Waiter,
        started: u64,
        acquired: bool,
        task: Z.Task,
    };

    fn nanotime() u64 {
        var ts = Z.zap.runtime.sync.OsFutex.Timestamp{};
        ts.current();
        return ts.nanos;
    }

    fn tryAcquireX86(self: *@This()) bool {
        return asm volatile(
            "lock btsw $0, %[ptr]"
            : [ret] "={@ccc}" (-> u8),
            : [ptr] "*m" (&self.state)
            : "cc", "memory"
        ) == 0;
    }

    fn acquireAsync(self: *@This()) void {
        const acquired = blk: {
            if (is_x86)
                break :blk self.tryAcquireX86();
            break :blk @cmpxchgWeak(
                usize,
                &self.state,
                UNLOCKED,
                LOCKED,
                .Acquire,
                .Monotonic,
            ) == null;
        };

        if (!acquired) {
            self.acquireSlow();
        }
    }

    fn acquireSlow(self: *@This()) void {
        @setCold(true);

        var waiter: Waiter = undefined;
        waiter.prev = null;
        waiter.started = 0;
        waiter.acquired = false;

        while (!waiter.acquired) {
            waiter.task = Z.Task.initAsync(@frame());

            suspend {
                var spin: u3 = 0;
                var state = @atomicLoad(usize, &self.state, .Monotonic);

                while (true) {
                    if (state & LOCKED == 0) {
                        if (is_x86) {
                            if (!self.tryAcquireX86()) {
                                Z.std.SpinLock.loopHint(1);
                                state = @atomicLoad(usize, &self.state, .Monotonic);
                                continue;
                            }
                        } else if (@cmpxchgWeak(
                            usize,
                            &self.state,
                            state,
                            state | LOCKED,
                            .Acquire,
                            .Monotonic,
                        )) |updated| {
                            state = updated;
                            continue;
                        }

                        waiter.acquired = true;
                        Z.Task.Batch.from(&waiter.task).schedule(.{ .use_next = true });
                        break;
                    }

                    const head = @intToPtr(?*Waiter, state & WAITING);
                    if (head == null and spin <= 3) {
                        spin += 1;
                        Z.std.SpinLock.loopHint(@as(usize, 1) << spin);
                        state = @atomicLoad(usize, &self.state, .Monotonic);
                        continue;
                    }

                    waiter.next = head;
                    waiter.tail = if (head == null) &waiter else null;
                    if (waiter.started == 0)
                        waiter.started = nanotime();

                    state = @cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        (state & ~WAITING) | @ptrToInt(&waiter),
                        .Release,
                        .Monotonic,
                    ) orelse break;
                }
            }
        }
    }

    fn release(self: *@This()) void {
        if (@cmpxchgWeak(
            usize,
            &self.state,
            LOCKED,
            UNLOCKED,
            .Release,
            .Monotonic,
        )) |_| {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *@This()) void {
        @setCold(true);

        var released: ?usize = null;
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            const head = @intToPtr(?*Waiter, state & WAITING) orelse {
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    state & ~LOCKED,
                    .Release,
                    .Monotonic,
                ) orelse return;
                continue;
            };

            @fence(.Acquire);
            const tail = head.tail orelse blk: {
                var current = head;
                while (true) {
                    const next = current.next.?;
                    next.prev = current;
                    current = next;
                    if (current.tail) |tail| {
                        head.tail = tail;
                        break :blk tail;
                    }
                }
            };

            const released_at = released orelse blk: {
                const now = nanotime();
                released = now;
                break :blk now;
            };
            const eventual_fairness_timeout = 1 * Z.std.time.ns_per_ms;
            const be_fair = (released_at - tail.started) >= eventual_fairness_timeout;

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                if (be_fair) {
                    @fence(.Release);
                } else {
                    _ = @atomicRmw(usize, &self.state, .And, ~LOCKED, .Release);
                }
            } else if (@cmpxchgWeak(
                usize,
                &self.state,
                state,
                if (be_fair) LOCKED else UNLOCKED,
                .Monotonic,
                .Monotonic,
            )) |updated| {
                state = updated;
                continue;
            }

            tail.prev = null;
            tail.acquired = be_fair;
            Z.Task.Batch.from(&tail.task).schedule(.{ .use_lifo = true });
            return;
        }
    }
};
