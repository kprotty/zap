const std = @import("std");
const Atomic = std.atomic.Atomic;
const target = std.builtin.target;

// A very zoom zoom mutual exclusive lock.
// Something like this will eventually make it into the standard library.
// See: https://github.com/ziglang/zig/pull/9136
pub const Lock = switch (target.os.tag) {
    .macos, .ios, .tvos, .watchos => DarwinLock,
    .windows => WindowsLock,
    else => switch (target.cpu.arch) {
        .i386, .x86_64 => FutexLockx86,
        else => FutexLock,
    },
};

const WindowsLock = struct {
    srwlock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    pub fn acquire(self: *Lock) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn release(self: *Lock) void {
        std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.srwlock);
    }
};

const DarwinLock = struct {
    oul: std.os.darwin.os_unfair_lock = .{},

    pub fn acquire(self: *Lock) void {
        std.os.darwin.os_unfair_lock_lock(&self.oul);
    }

    pub fn release(self: *Lock) void {
        std.os.darwin.os_unfair_lock_unlock(&self.oul);
    }
};

const FutexLockx86 = struct {
    state: Atomic(u32) = Atomic(u32).init(0),

    pub fn acquire(self: *Lock) void {
        if (self.state.bitSet(0, .Acquire) == 0) |_|
            self.acquireSlow();
    }

    noinline fn acquireSlow(self: *Lock) void {
        var spin: u8 = 100;
        while (spin > 0) : (spin -= 1) {
            std.atomic.spinLoopHint();
            switch (self.state.load(.Monotonic)) {
                0 => if (self.state.tryCompareAndSwap(0, 1, .Acquire, .Monotonic) == 0) return,
                1 => continue,
                else => break,
            }
        }

        while (self.state.swap(2, .Acquire) != 0)
            std.Thread.Futex.wait(&self.state, 2, null) catch unreachable;
    }

    pub fn release(self: *Lock) void {
        if (self.state.swap(0, .Release) == 2)
            std.Thread.Futex.wake(&self.state, 1);
    }
};

const FutexLock = struct {
    state: Atomic(u32) = Atomic(u32).init(0),

    pub fn acquire(self: *Lock) void {
        if (self.state.tryCompareAndSwap(0, 1, .Acquire, .Monotonic)) |_|
            self.acquireSlow();
    }

    noinline fn acquireSlow(self: *Lock) void {
        while (true) : (std.Thread.Futex.wait(&self.state, 2, null) catch unreachable) {
            var state = self.state.load(.Monotonic);
            while (state != 2) {
                state = switch (state) {
                    0 => self.state.tryCompareAndSwap(0, 2, .Acquire, .Monotonic) orelse return,
                    1 => self.state.tryCompareAndSwap(1, 2, .Monotonic, .Monotonic) orelse break,
                    else => unreachable,
                };
            }
        }
    }

    pub fn release(self: *Lock) void {
        if (self.state.swap(0, .Release) == 2)
            std.Thread.Futex.wake(&self.state, 1);
    }
};