// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

pub const Lock = if (std.builtin.os.tag == .windows)
    WindowsLock
else if (std.Target.current.isDarwin())
    DarwinLock
else if (std.builtin.link_libc)
    PosixLock
else if (std.builtin.os.tag == .linux)
    LinuxLock
else 
    @compileError("Unimplemented Lock primitive for platform");

const WindowsLock = struct {
    srwlock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Self) Held {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.srwlock);
        return Held{ .lock = self };
    }

    pub const Held = struct {
        lock: *Self,

        pub fn release(self: Held) void {
            std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.lock.srwlock);
        }
    };
};

const DarwinLock = extern struct {
    os_unfair_lock: u32 = 0,

    const Self = @This();
    extern fn os_unfair_lock_lock(lock: *Self) void;
    extern fn os_unfair_lock_unlock(lock: *Self) void;

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Self) Held {
        os_unfair_lock_lock(self);
        return Held{ .lock = self };
    }

    pub const Held = struct {
        lock: *Self,

        pub fn release(self: Held) void {
            os_unfair_lock_unlock(self.lock);
        }
    };
};

const PosixLock = struct {
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        const rc = std.c.pthread_mutex_destroy(&self.mutex);
        std.debug.assert(rc == 0 or rc == std.os.EINVAL);
        self.* = undefined;
    }

    pub fn acquire(self: *Self) Held {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        return Held{ .lock = self };
    }

    pub const Held = struct {
        lock: *Self,

        pub fn release(self: Held) void {
            std.debug.assert(std.c.pthread_mutex_unlock(&self.lock.mutex) == 0);
        }
    };
};

const LinuxLock = struct {
    state: State = .Unlocked,

    const Self = @This();
    const State = enum(i32) {
        Unlocked = 0,
        Locked,
        Contended,
    };

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Self) Held {
        if (atomic.compareAndSwap(
            &self.state,
            .Unlocked,
            .Locked,
            .Acquire,
            .Relaxed,
        )) |_| {
            self.acquireSlow();
        }

        return Held{ .lock = self };
    }

    fn acquireSlow(self: *Self) void {
        @setCold(true);

        var spin: usize = 0;
        var lock_state = State.Locked;
        var state = atomic.load(&self.state, .Relaxed);
        
        while (true) {
            if (state == .Unlocked) {
                state = atomic.tryCompareAndSwap(
                    &self.state,
                    state,
                    lock_state,
                    .Acquire,
                    .Relaxed,
                ) orelse return;
                atomic.spinLoopHint();
                continue;
            }

            if (state == .Locked and spin < 100) {
                spin += 1;
                atomic.spinLoopHint();
                state = atomic.load(&self.state, .Relaxed);
            }

            if (state != .Contended) {
                if (atomic.tryCompareAndSwap(
                    &self.state,
                    state,
                    .Contended,
                    .Relaxed,
                    .Relaxed,
                )) |updated| {
                    atomic.spinLoopHint();
                    state = updated;
                    continue;
                }
            }

            switch (std.os.linux.getErrno(std.os.linux.futex_wait(
                @ptrCast(*const i32, &self.state),
                std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAIT,
                @enumToInt(State.Contended),
                null,
            ))) {
                0 => {},
                std.os.EINTR => {},
                std.os.EAGAIN => {},
                std.os.ETIMEDOUT => unreachable,
                else => unreachable,
            }

            spin = 0;
            lock_state = .Contended;
            state = atomic.load(&self.state, .Relaxed);
        }
    }

    pub const Held = struct {
        lock: *Self,

        pub fn release(self: Held) void {
            switch (atomic.swap(&self.lock.state, .Unlocked, .Release)) {
                .Unlocked => unreachable,
                .Locked => {},
                .Contended => self.releaseSlow(),
            }
        }

        fn releaseSlow(self: Held) void {
            @setCold(true);

            switch (std.os.linux.getErrno(std.os.linux.futex_wake(
                @ptrCast(*const i32, &self.lock.state),
                std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAKE,
                1,
            ))) {
                0 => {},
                std.os.EINVAL => {},
                std.os.EACCES => {},
                std.os.EFAULT => {},
                else => unreachable,
            }
        }
    };
};