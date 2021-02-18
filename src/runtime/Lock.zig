const std = @import("std");

pub usingnamespace if (std.builtin.os.tag == .windows)
    WindowsLock
else if (std.Target.current.isDarwin())
    DarwinLock
else if (std.builtin.link_libc)
    PosixLock
else if (std.builtin.os.tag == .linux)
    LinuxLock
else
    SpinLock;

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
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.lock);
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
        assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
    }

    pub fn release(self: *@This()) void {
        assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);
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

const SpinLock = struct {
    locked: bool = false,

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn tryAcquire(self: *@This()) bool {
        return @atomicRmw(bool, &self.locked, .Xchg, true, .Acquire) == false;
    }

    pub fn acquire(self: *@This()) void {
        while (!self.tryAcquire())
            std.Thread.spinLoopHint();
    }

    pub fn release(self: *@This()) void {
        @atomicStore(bool, &self.locked, false, .Release);
    }
};
