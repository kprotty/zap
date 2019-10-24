const std = @import("std");
const builtin = @import("builtin");

const zync = @import("../../zap.zig").zync;
const zuma = @import("../../zap.zig").zuma;

const c = std.c;
const expect = std.testing.expect;

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

pub const Mutex = struct {
    const SpinCpu = 4;
    const SpinThread = 1;
    const SpinCpuCount = 40;
    
    futex: zync.Futex,
    state: zync.Atomic(enum(u32) {
        Unlocked,
        Sleeping,
        Locked,
    }),

    pub fn init(self: *@This()) void {
        self.state.set(.Unlocked);
        self.futex.init();
    }

    pub fn deinit(self: *@This()) void {
        self.futex.deinit();
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
            for ([SpinCpu]void(undefined)) |_| {
                while ((self.state.compareSwap(.Unlocked, state, .Acquire, .Relaxed) orelse return) != .Unlocked) {}
                zync.yield(SpinCpuCount);
            }

            // try and acquire the lock using thread rescheduling on failure
            for ([SpinThread]void(undefined)) |_| {
                while ((self.state.compareSwap(.Unlocked, state, .Acquire, .Relaxed) orelse return) != .Unlocked) {}
                zuma.Thread.yield();
            }

            // failed to acquire the lock, go to unsleep until woken up by `.release()`
            if (self.state.swap(.Sleeping, .Acquire) == .Unlocked)
                return;
            state = .Sleeping;
            self.futex.wait(@ptrCast(*const u32, &self.state), u32(state), null) catch unreachable;
        }
    }

    pub fn release(self: *@This()) void {
        switch (self.state.swap(.Unlocked, .Release)) {
            .Sleeping => self.futex.notify(@ptrCast(*const u32, &self.state), 1),
            .Unlocked => @panic("Unlocking an unlocked mutex"),
            .Locked => {},
        }
    }
};

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
    var state: LockState = undefined;
    state.init();
    defer state.deinit();

    // test tryAcquire + release
    expect(lock.tryAcquire() == true);
    lock.release();

    // test acquire + release
    lock.acquire();
    expect(state.value == 0);
    const thread = try zuma.Thread.spawn(LockState.updateAndRelease, state);
    defer thread.join() catch unreachable;
    lock.acquire();
    expect(state.value == 1);
    lock.release();

    // test tryAcquire + release once more after the acquire + release tests
    expect(lock.tryAcquire() == true);
    lock.release();
}