const std = @import("std");
const builtin = @import("builtin");

const zync = @import("../../zap.zig").zync;
const zuma = @import("../../zap.zig").zuma;

const c = std.c;
const expect = std.testing.expect;
const expectError = std.testing.expectError;

pub const Event = struct {
    pub const AutoReset = EventImpl(true);
    pub const ManualReset = EventImpl(false);

    fn EventImpl(comptime auto_reset: bool) type {
        return struct {
            futex: zync.Futex,
            state: zync.Atomic(EventState),

            const EventState = enum(u32) {
                Empty,
                Signaled,
            };

            pub fn init(self: *@This()) void {
                self.state.set(.Empty);
                self.futex.init();
            }

            pub fn deinit(self: *@This()) void {
                self.futex.deinit();
            }

            pub fn isSet(self: *const @This()) bool {
                return self.state.load(.Relaxed) == .Signaled;
            }

            pub fn set(self: *@This()) void {
                if (self.state.swap(.Signaled, .Release) == .Empty)
                    self.futex.notifyOne(@ptrCast(*const u32, &self.state));
            }

            pub fn reset(self: *@This()) void {
                std.debug.assert(self.state.swap(.Empty, .Release) == .Signaled);
            }

            pub fn wait(self: *@This(), timeout_ms: u32) zync.Futex.WaitError!void {
                const expected = @enumToInt(EventState.Empty);
                try self.futex.wait(@ptrCast(*const u32, &self.state), expected, timeout_ms);
                if (auto_reset)
                    self.reset();
            }
        };
    }
};

test "Event" {
    var event: Event.AutoReset = undefined;
    event.init();
    defer event.deinit();

    // test .set() and .reset();
    expect(event.isSet() == false);
    event.set();
    expect(event.isSet() == true);
    event.reset();
    expect(event.isSet() == false);

    const delay_ms = 100;
    const threshold_ms = 300;
    const max_delay = delay_ms + threshold_ms;
    const min_delay = delay_ms - std.math.min(delay_ms, threshold_ms);

    // test .wait() delay
    const now = zuma.Thread.now(.Monotonic);
    expectError(zync.Futex.WaitError.TimedOut, event.wait(delay_ms));
    const elapsed = zuma.Thread.now(.Monotonic) - now;
    expect(elapsed > min_delay and elapsed < max_delay);

    const EventNotifier = struct {
        pub fn notify(self: *Event.AutoReset) void {
            zuma.Thread.sleep(100);
            self.set();
        }
    };

    // test cross thread notification
    var thread = try zuma.Thread.spawn(EventNotifier.notify, &event, null);
    defer thread.join(null) catch unreachable;
    try event.wait(500);
    expect(event.isSet() == false);
}

pub const Spinlock = struct {
    state: zync.Atomic(bool),

    pub fn deinit(self: *@This()) void {}
    pub fn init(self: *@This()) void {
        self.state.set(false);
    }

    pub fn tryAcquire(self: *@This()) bool {
        return self.state.swap(true, .Acquire) == false;
    }

    pub fn acquire(self: *@This()) void {
        // simple exponential backoff
        var backoff: usize = 1;
        while (!self.tryAcquire()) : (backoff <<= 1)
            zync.yield(backoff);
    }

    pub fn release(self: *@This()) void {
        self.state.store(false, .Release);
    }
};

test "Spinlock" {
    try testLockImplementation(Spinlock);
}

pub const Mutex = RawMutex(zync.Futex.ThreadParker);
pub fn RawMutex(comptime ThreadParker: type) type {
    return struct {
        const SpinCpu = 4;
        const SpinThread = 1;
        const SpinCpuCount = 40;

        parker: ThreadParker,
        state: zync.Atomic(MutexState),

        const MutexState = enum(u32) {
            Unlocked,
            Sleeping,
            Locked,
        };

        pub fn init(self: *@This(), args: ...) @typeOf(ThreadParker.init).ReturnType {
            self.state.set(.Unlocked);
            return self.parker.init(@ptrCast(*const u32, &self.state));
        }

        pub fn deinit(self: *@This()) @typeOf(ThreadParker.deinit).ReturnType {
            return self.parker.deinit();
        }

        pub fn tryAcquire(self: *@This()) bool {
            return self.state.compareSwap(.Unlocked, .Locked, .Acquire, .Relaxed) == null;
        }

        pub fn acquire(self: *@This()) void {
            // Speculatively grab the lock.
            // If it fails, state is either .Locked or .Sleeping
            // depending on if theres a thread stuck sleeping below.
            var state = self.state.swap(.Locked, .Acquire);
            if (state == .Unlocked)
                return;

            while (true) {
                // try and acquire the lock using cpu spinning on failure
                for (([SpinCpu]void)(undefined)) |_| {
                    var value = self.state.load(.Relaxed);
                    while (value == .Unlocked)
                        value = self.state.compareSwap(.Unlocked, state, .Acquire, .Relaxed) orelse return;
                    zync.yield(SpinCpuCount);
                }

                // try and acquire the lock using thread rescheduling on failure
                for (([SpinThread]void)(undefined)) |_| {
                    var value = self.state.load(.Relaxed);
                    while (value == .Unlocked)
                        value = self.state.compareSwap(.Unlocked, state, .Acquire, .Relaxed) orelse return zuma.Thread.yield();
                }

                // failed to acquire the lock, go to unsleep until woken up by `.release()`
                if (self.state.swap(.Sleeping, .Acquire) == .Unlocked)
                    return;
                state = .Sleeping;
                _ = self.parker.park(@ptrCast(*const u32, &self.state), @enumToInt(state));
            }
        }

        pub fn release(self: *@This()) void {
            switch (self.state.swap(.Unlocked, .Release)) {
                .Sleeping => {
                    _ = self.parker.wake(@ptrCast(*const u32, &self.state));
                },
                .Unlocked => unreachable,
                .Locked => {},
            }
        }
    };
}

test "Mutex" {
    try testLockImplementation(Mutex);
}

fn testLockImplementation(comptime Lock: type) !void {
    const LockState = struct {
        lock: Lock,
        value: usize,

        pub fn init(self: *@This()) void {
            self.value = 0;
            self.lock.init();
        }

        pub fn deinit(self: *@This()) void {
            self.lock.deinit();
        }

        pub fn updateAndRelease(self: *@This()) void {
            zuma.Thread.sleep(100); // small delay to make sure other thread acquire blocks
            self.value = 1;
            self.lock.release();
        }
    };

    // test init / deinit
    var self: LockState = undefined;
    self.init();
    defer self.deinit();

    // test tryAcquire + release
    expect(self.lock.tryAcquire() == true);
    self.lock.release();

    // test acquire + release
    self.lock.acquire();
    expect(self.value == 0);
    var thread = try zuma.Thread.spawn(LockState.updateAndRelease, &self, null);
    defer thread.join(null) catch unreachable;
    self.lock.acquire();
    expect(self.value == 1);
    self.lock.release();

    // test tryAcquire + release once more after the acquire + release tests
    expect(self.lock.tryAcquire() == true);
    self.lock.release();
}

pub const Barrier = struct {
    futex: zync.Futex,
    signals: zync.Atomic(u32),

    pub fn init(self: *@This(), signals_needed: u32) void {
        self.futex.init();
        self.signals.set(signals_needed);
    }

    pub fn deinit(self: *@This()) void {
        self.futex.deinit();
    }

    pub fn signal(self: *@This()) void {
        if (self.signals.load(.Relaxed) == 0)
            return;
        if (self.signals.fetchSub(1, .Relaxed) == 1)
            self.futex.notifyOne(@ptrCast(*const u32, &self.signals));
    }

    pub fn wait(self: *@This(), timeout_ms: ?u32) zync.Futex.WaitError!void {
        var timeout = timeout_ms;
        const now = if (timeout != null) zuma.Thread.now(.Monotonic) else 0;
        var signals = self.signals.load(.Relaxed);
        while (signals > 0) {
            try self.futex.wait(@ptrCast(*const u32, &self.signals), signals, timeout);
            if (timeout) |t| {
                const elapsed_ms = zuma.Thread.now(.Monotonic) - t;
                if (elapsed_ms > t)
                    return zync.Futex.WaitError.TimedOut;
                timeout = t - @intCast(@typeOf(t), elapsed_ms);
            }
            signals = self.signals.load(.Relaxed);
        }
    }
};

test "Barrier" {
    try struct {
        barrier: Barrier,

        pub fn signal(self: *@This()) void {
            self.barrier.signal();
        }

        pub fn run() !void {
            // create the barrier
            const signals_needed = 3;
            var self: @This() = undefined;
            self.barrier.init(signals_needed);
            defer self.barrier.deinit();

            // spawn signalers (+ 1 to test .signal() call overflow)
            var signalers: [signals_needed + 1]zuma.Thread.JoinHandle = undefined;
            for (signalers) |*signaler|
                signaler.* = try zuma.Thread.spawn(signal, &self, null);

            // wait for signalers to complete on the barrier + clean up signaler threads
            try self.barrier.wait(1000);
            for (signalers) |*signaler|
                try signaler.join(100);
        }
    }.run();
}
