const std = @import("std");
const assert = std.debug.assert;

const ThreadPool = @This();

max_threads: u16,
counter: u32 = 0,
spawned: ?*Worker = null,
idle_sema: Semaphore = .{},
shutdown_sema: Semaphore = .{},

pub const InitConfig = struct {
    max_threads: ?u16 = null,
};

pub fn init(config: InitConfig) ThreadPool {
    return .{
        .max_threads = std.math.min(
            std.math.maxInt(u14),
            std.math.max(1, config.max_threads orelse blk: {
                break :blk @intCast(u16, std.Thread.cpuCount() catch 1);
            }),
        ),
    };
}

const Semaphore = struct {
    permits: u32 = 0,
    futex: Futex = .{},

    fn deinit(self: *Semaphore) void {
        self.futex.deinit();
        self.* = undefined;
    }

    fn wait(self: *Semaphore) void {
        var permits = @atomicLoad(u32, &self.permits, .Monotonic);
        while (true) {
            var new_permits: ?u32 = null;
            if ((permits >> 1) != 0) {
                new_permits = (permits - (1 << 1)) & ~@as(u32, 1);
            } else if (permits == 0) {
                new_permits = 1;
            }

            if (new_permits) |new| {
                if (@cmpxchgWeak(
                    u32,
                    &self.permits,
                    permits,
                    new,
                    .Acquire,
                    .Monotonic,
                )) |updated| {
                    permits = updated;
                    continue;
                }
            }

            if (new_permits != 1) return;
            Futex.wait(@ptrCast(*const i32, &self.permits), 1);
            permits = @atomicLoad(u32, &self.permits, .Monotonic);
        }
    }

    fn post(self: *Semaphore) void {
        const permits = @atomicRmw(u32, &self.permits, 1 << 1, .Release);
        if (permits == 1) {
            const waiters = std.math.maxInt(i32);
            Futex.wake(@ptrCast(*const i32, &self.permits), waiters);
        }
    }
};

const Futex = if (std.builtin.os.tag == .windows)
    WindowsFutex
else if (std.Target.current.isDarwin())
    DarwinFutex
else if (std.builtin.os.tag == .linux)
    LinuxFutex
else if (std.builtin.link_libc)
    PosixFutex
else
    SpinFutex;

const WindowsFutex = struct {
    lock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,
    cond: std.os.windows.CONDITION_VARIABLE = std.os.windows.CONDITION_VARIABLE_INIT,

    fn deinit(self: *@This()) void {
        // no-op
    }

    fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.lock);
        defer std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.lock);

        while (@atomicLoad(i32, ptr, .Acquire) == cmp) {
            _ = std.os.windows.kernel32.SleepConditionVariableSRW(
                &self.cond,
                &self.lock,
                std.os.windows.INFINITE,
                0,
            );
        }
    }

    fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        switch (waiters) {
            0 => {},
            1 => std.os.windows.kernel32.WakeConditionVariable(&self.cond),
            else => std.os.windows.kernel32.WakeAllConditionVariable(&self.cond),
        }
    }
};

const DarwinFutex = struct {
    fn deinit(self: *@This()) void {
        // no-op
    }

    fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        _ = __ulock_wait(
            UL_COMPARE_AND_WAIT | ULF_NO_ERRNO,
            @ptrCast(*const c_void, ptr),
            @bitCast(u32, cmp),
            0,
        );
    }

    fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        var flags: u32 = ;
        if (waiters > 1) {
            flags |= ULF_WAKE_ALL;
        }

        while (true) {
            const rc = __ulock_wake(
                UL_COMPARE_AND_WAIT | ULF_NO_ERRNO | (if (waiters > 1) ULF_WAKE_ALL else 0),
                @ptrCast(*const c_void, ptr),
                0,
            );
            if (rc == -std.os.EINTR) continue;
            return;
        }
    }

    const UL_COMPARE_AND_WAIT = 1;
    const ULF_NO_ERRNO = 0x1000000;
    const ULF_WAKE_ALL = 0x100;
    extern "c" fn __ulock_wait(op: u32, addr: ?*const c_void, val: u64, timeout_us: u32) c_int;
    extern "c" fn __ulock_wake(op: u32, addr: ?*const c_void, val: u64) c_int;
};

const LinuxFutex = struct {
    fn deinit(self: *@This()) void {
        // no-op
    }

    fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        switch (std.os.linux.getErrno(std.os.linux.futex_wait(
            ptr,
            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAIT,
            cmp,
            null,
        ))) {
            0 => {},
            std.os.EINTR => {},
            std.os.EAGAIN => {},
            else => unreachable,
        }
    }

    fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        switch (std.os.linux.getErrno(std.os.linux.futex_wake(
            ptr,
            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAKE,
            waiters,
        ))) {
            0 => {},
            std.os.EFAULT => {},
            else => unreachable,
        }
    }
};

const PosixFutex = struct {
    cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    fn deinit(self: *@This()) void {
        _ = std.c.pthread_cond_destroy(&self.cond);
        _ = std.c.pthread_mutex_destroy(&self.mutex);
    }

    fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

        while (@atomicLoad(i32, ptr, .Acquire) == cmp) {
            assert(std.c.pthread_cond_wait(&self.cond, &self.mutex) == 0);
        }
    }

    fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        switch (waiters) {
            0 => {},
            1 => assert(std.c.pthread_cond_signal(&self.cond) == 0),
            else => assert(std.c.pthread_cond_broadcast(&self.cond) == 0),
        }
    }
};

const SpinFutex = struct {
    fn deinit(self: *@This()) void {
        // no-op
    }

    fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        while (@atomicLoad(i32, ptr, .Acquire) == cmp) {
            spinLoopHint();
        }
    }

    fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        // no-op
    }
};

const spinLoopHint = std.Thread.spinLoopHint;