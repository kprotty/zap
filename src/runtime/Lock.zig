const std = @import("std");

pub const Lock = if (std.builtin.os.tag == .windows)
    WindowsLock
else if (std.Target.current.isDarwin())
    DarwinLock
else if (std.builtin.link_libc)
    PosixLock
else if (std.builtin.os.tag == .linux)
    LinuxLock
else
    @compileError("Platform not supported");

const WindowsLock = struct {
    lock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn tryAcquire(self: *@This()) bool {
        return std.os.windows.kernel32.TryAcquireSRWLockExclusive(&self.lock) != 0;
    }

    pub fn acquire(self: *@This()) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.lock);
    }

    pub fn release(self: *@This()) void {
        std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.lock);
    }
};

const PosixLock = struct {
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn deinit(self: *@This()) void {
        _ = std.c.pthread_mutex_destroy(&self.mutex);
    }

    pub fn tryAcquire(self: *@This()) bool {
        return std.c.pthread_mutex_trylock(&self.mutex) == 0;
    }

    pub fn acquire(self: *@This()) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
    }

    pub fn release(self: *@This()) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);
    }
};

const DarwinLock = struct {
    oul: u32 = 0,

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn tryAcquire(self: *@This()) bool {
        return os_unfair_lock_trylock(&self.oul);
    }

    pub fn acquire(self: *@This()) void {
        os_unfair_lock_lock(&self.oul);
    }

    pub fn release(self: *@This()) void {
        os_unfair_lock_unlock(&self.oul);
    }

    extern "c" fn os_unfair_lock_lock(oul: *u32) callconv(.C) void;
    extern "c" fn os_unfair_lock_unlock(oul: *u32) callconv(.C) void;
    extern "c" fn os_unfair_lock_trylock(oul: *u32) callconv(.C) bool;
};

const LinuxLock = struct {
    state: State = .unlocked,

    const Futex = @import("./Futex.zig").Futex;
    const State = enum(u32) {
        unlocked,
        locked,
        contended,
    };

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn tryAcquire(self: *@This()) bool {
        return @cmpxchgStrong(
            State,
            &self.state,
            .unlocked,
            .locked,
            .Acquire,
            .Monotonic,
        ) == null;
    }

    pub fn acquire(self: *@This()) void {
        const state = @atomicRmw(State, &self.state, .Xchg, .locked, .Acquire);
        if (state != .unlocked) {
            self.acquireSlow(state);
        }
    }

    fn acquireSlow(self: *@This(), current_state: State) void {
        @setCold(true);

        var adaptive_spin: usize = 0;
        var new_state = current_state;
        while (true) {
            var state = @atomicLoad(State, &self.state, .Monotonic);

            if (state == .unlocked) {
                state = @cmpxchgStrong(
                    State,
                    &self.state,
                    .unlocked,
                    new_state,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
            }

            if (state != .contended and Futex.yield(adaptive_spin)) {
                adaptive_spin +%= 1;
                continue;
            }

            new_state = .contended;
            if (state != .contended) {
                state = @atomicRmw(State, &self.state, .Xchg, .contended, .Acquire);
                if (state == .unlocked) {
                    return;
                }
            }

            adaptive_spin = 0;
            Futex.wait(
                @ptrCast(*const u32, &self.state),
                @enumToInt(State.contended),
                null,
            ) catch unreachable;
        }
    }

    pub fn release(self: *@This()) void {
        switch (@atomicRmw(State, &self.state, .Xchg, .unlocked, .Release)) {
            .unlocked => unreachable,
            .locked => {},
            .contended => self.releaseSlow(),
        } 
    }

    fn releaseSlow(self: *@This()) void {
        @setCold(true);
        Futex.wake(@ptrCast(*const u32, &self.state), 1);
    }
};
