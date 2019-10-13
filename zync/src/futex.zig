const std = @import("std");
const builtin = @import("builtin");

const zync = @import("../../zap.zig").zync;
const zuma = @import("../../zap.zig").zuma;

const os = std.os;
const system = os.system;
const expect = std.testing.expect;
const expectError = std.testing.expectError;

const Backend = switch (builtin.os) {
    .linux => if (builtin.link_libc) Posix else Linux,
    .windows => Windows,
    else => Posix,
};

pub const Futex = struct {
    inner: Backend,

    pub fn init(self: *@This()) void {
        self.inner.init();
    }

    pub fn deinit(self: *@This()) void {
        self.inner.deinit();
    }

    pub const WaitError = error{TimedOut};

    pub fn wait(self: *@This(), ptr: *const u32, expected: u32, timeout_ms: ?u32) WaitError!void {
        if (@atomicLoad(u32, ptr, .Monotonic) != expected)
            return;
        return self.inner.wait(ptr, expected, timeout_ms);
    }

    pub fn notifyOne(self: *@This(), ptr: *const u32) void {
        self.inner.notify(ptr, i32(1));
    }

    pub fn notifyAll(self: *@This(), ptr: *const u32) void {
        self.inner.notify(ptr, std.math.maxInt(i32));
    }
};

const Linux = struct {
    pub fn init(self: *@This()) void {}
    pub fn deinit(self: *@This()) void {}

    pub fn notify(self: *@This(), ptr: *const u32, wakeup_count: i32) void {
        const addr = @ptrCast(*const i32, ptr);
        const flags = system.FUTEX_WAKE | system.FUTEX_PRIVATE_FLAG;
        return switch (os.errno(system.futex_wake(addr, flags, wakeup_count))) {
            0 => {},
            os.EACCES, os.EFAULT, os.EINVAL, os.ETIMEDOUT => unreachable,
            else => unreachable,
        };
    }

    pub fn wait(self: *@This(), ptr: *const u32, expected: u32, timeout_ms: ?u32) Futex.WaitError!void {
        var ts: os.timespec = undefined;
        var ts_ptr: ?*os.timespec = null;
        if (timeout_ms) |timeout| {
            if (timeout > 0) {
                ts.tv_nsec = (timeout % 1000) * 1000000;
                ts.tv_sec = timeout / 1000;
                ts_ptr = &ts;
            }
        }

        const value = @bitCast(i32, expected);
        const addr = @ptrCast(*const i32, ptr);
        const flags = system.FUTEX_WAIT | system.FUTEX_PRIVATE_FLAG;
        while (true) {
            switch (os.errno(system.futex_wait(addr, flags, value, ts_ptr))) {
                0, os.EAGAIN => return,
                os.EACCES, os.EFAULT, os.EINVAL, os.ENOSYS => unreachable,
                os.ETIMEDOUT => return Futex.WaitError.TimedOut,
                os.EINTR => continue,
                else => unreachable,
            }
        }
    }
};

const Windows = struct {
    pub fn init(self: *@This()) void {}
    pub fn deinit(self: *@This()) void {}
    
    pub fn notify(self: *@This(), ptr: *const u32, wakeup_count: i32) void {
        const addr = @ptrCast(*const c_void, ptr);
        return switch (wakeup_count) {
            1 => Synchronization.get().?.WakeByAddressSingle(addr),
            else => Synchronization.get().?.WakeByAddressAll(addr),
        };
    }

    pub fn wait(self: *@This(), ptr: *const u32, expected: u32, timeout_ms: ?u32) Futex.WaitError!void {
        var compare = expected;
        const addr = @ptrCast(*const c_void, ptr);
        const compare_addr = @ptrCast(*const c_void, &compare);

        const timeout = timeout_ms orelse system.INFINITE;
        if (Synchronization.get().?.WaitOnAddress(addr, compare_addr, @sizeOf(@typeOf(expected)),  timeout) == system.TRUE)
            return;
        return switch (system.kernel32.GetLastError()) {
            ERROR_TIMEOUT => Futex.WaitError.TimedOut,
            else => unreachable,
        };
    }

    const ERROR_TIMEOUT = 1460;
    const Synchronization = zuma.backend.DynamicLibrary(c"api-ms-win-core-synch-l1-2-0", struct {
        WakeByAddressAll: extern fn (Address: *const c_void) void,
        WakeByAddressSingle: extern fn (Address: *const c_void) void,
        WaitOnAddress: extern fn (
            Address: *const c_void,
            CompareAddress: *const c_void,
            AddressSize: system.SIZE_T,
            dwMilliseconds: system.DWORD,
        ) system.BOOL,
    });
};

const Posix = struct {
    cond: system.pthread_cond_t,
    mutex: system.pthread_mutex_t,

    pub fn init(self: *@This()) void {
        std.debug.assert(system.pthread_cond_init(&self.cond, null) == 0);
        std.debug.assert(system.pthread_mutex_init(&self.mutex, null) == 0);
    }

    pub fn deinit(self: *@This()) void {
        std.debug.assert(system.pthread_mutex_destroy(&self.mutex) == 0);
        std.debug.assert(system.pthread_cond_destroy(&self.cond) == 0);
    }

    pub fn notify(self: *@This(), ptr: *const u32, wakeup_count: i32) void {
        std.debug.assert(switch (wakeup_count) {
            1 => system.pthread_cond_signal(&self.cond),
            else => system.pthread_cond_broadcast(&self.cond),
        } == 0);
    }

    pub fn wait(self: *@This(), ptr: *const u32, expect: u32, timeout_ms: ?u32) Futex.WaitError!void {
        std.debug.assert(system.pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(system.pthread_mutex_unlock(&self.mutex) == 0);

        return switch (os.errno(result: {
            if (timeout_ms) |timeout| {
                var ts = os.timespec{
                    .tv_nsec = (timeout % 1000) * 1000000,
                    .tv_sec = timeout / 1000,
                };
                break :result system.pthread_cond_timedwait(&self.cond, &self.mutex, &ts);
            } else {
                break :result system.pthread_cond_wait(&self.cond, &self.mutex);
            }
        })) {
            0 => {},
            os.ETIMEDOUT => Futex.WaitError.TimedOut,
            else => unreachable,
        };
    }
};

test "Futex" {
    // test futex initialization & value
    const FutexValue = struct {
        value: zync.Atomic(u32),
        inner: Futex,
    };

    var futex: FutexValue = undefined;
    futex.value.set(0);
    futex.inner.init();
    defer futex.inner.deinit();
    expect(futex.value.get() == 0);

    const delay_ms = 100;
    const threshold_ms = 300;
    const max_delay = delay_ms + threshold_ms;
    const min_delay = delay_ms - std.math.min(delay_ms, threshold_ms);

    // Test .wait() delay
    const now = zuma.Thread.now(.Monotonic);
    expectError(Futex.WaitError.TimedOut, futex.inner.wait(&futex.value.value, 0, delay_ms));
    const elapsed = zuma.Thread.now(.Monotonic) - now;
    expect(elapsed > min_delay and elapsed < max_delay);

    const FutexNotifier = struct {
        // update the value and notify the futex
        pub fn run(ptr: usize) void {
            const self = @intToPtr(*FutexValue, ptr & ~usize(1));
            _ = self.value.fetchAdd(1, .Relaxed);
            if ((ptr & 1) != 0) {
                self.inner.notifyAll(&self.value.value);
            } else {
                self.inner.notifyOne(&self.value.value);
            }
        }

        // Create a thread for run()
        pub fn spawn(self: *FutexValue, notify_all: bool) !zuma.Thread {
            const ptr = @ptrToInt(self) | usize(@bitCast(u1, notify_all));
            const stack_size = zuma.Thread.getStackSize(run);
            if (stack_size > 0) {
                const allocator = std.debug.global_allocator;
                const stack = try allocator.alignedAlloc(u8, zuma.page_size, stack_size);
                defer allocator.free(stack);
                return try zuma.Thread.spawn(stack, run, ptr);
            } else {
                return try zuma.Thread.spawn(null, run, ptr);
            }
        }
    };

    // Spawn threads which update the futex & use both notifyOne() and notifyAll()
    var notify_all_thread = try FutexNotifier.spawn(&futex, true);
    defer _ = notify_all_thread.join(100);
    var notify_one_thread = try FutexNotifier.spawn(&futex, false);
    defer _ = notify_one_thread.join(100);
    while (futex.value.load(.Relaxed) != 2)
        try futex.inner.wait(&futex.value.value, futex.value.get(), 500);
    expect(futex.value.get() == 2);
}
