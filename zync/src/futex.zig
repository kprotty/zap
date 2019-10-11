const std = @import("std");
const builtin = @import("builtin");
const zync = @import("../../zap.zig").zync;

const os = std.os;
const system = os.system;
const expect = std.testing.expect;

pub const Futex = struct {
    value: zync.Atomic(u32),
    inner: Backend,

    pub fn init(self: *@This(), value: u32) void {
        self.value.set(value);
        self.inner.init();
    }

    pub fn deinit(self: *@This()) void {
        self.inner.deinit();
    }

    pub const WaitError = error{TimedOut};

    pub fn wait(self: *@This(), expect: u32, timeout_ms: ?u32) WaitError!void {
        try self.inner.wait(&self.value.value, expect, timeout_ms);
    }

    pub fn notifyOne(self: *@This()) void {
        self.inner.notify(&self.value.value, i32(1));
    }

    pub fn notifyAll(self: *@This()) void {
        self.inner.notify(&self.value.value, std.math.maxInt(i32));
    }
};

const Backend = switch (builtin.os) {
    .linux => struct {
        pub fn init(self: *@This()) void {}
        pub fn deinit(self: *@This()) void {}

        pub fn notify(self: *@This(), ptr: *u32, wakeup_count: i32) void {
            const addr = @ptrCast(*const i32, ptr);
            const flags = system.FUTEX_WAKE | system.FUTEX_PRIVATE_FLAG;
            return switch (os.errno(system.futex_wake(addr, flags, wakeup_count))) {
                0 => {},
                os.EACCES, os.EFAULT, os.EINVAL, os.ETIMEDOUT => unreachable,
                else => unreachable,
            };
        }

        pub fn wait(self: *@This(), ptr: *u32, expect: u32, timeout_ms: ?u32) Futex.WaitError!void {
            var ts: os.timespec = undefined;
            var ts_ptr: ?*os.timespec = null;
            if (timeout_ms) |timeout| {
                if (timeout > 0) {
                    ts.tv_nsec = (timeout % 1000) * 1000000;
                    ts.tv_sec = timeout / 1000;
                    ts_ptr = &ts;
                }
            }

            const value = @bitCast(i32, expect);
            const addr = @ptrCast(*const i32, ptr);
            const flags = system.FUTEX_WAIT | system.FUTEX_PRIVATE_FLAG | system.FUTEX_CLOCK_REALTIME;
            while (true) {
                switch (os.errno(system.futex_wait(addr, flags, value, ts_ptr))) {
                    0 => return,
                    os.EACCES, os.EAGAIN, os.EFAULT, os.EINVAL, os.ENOSYS => unreachable,
                    os.ETIMEDOUT => return Futex.WaitError.TimedOut,
                    os.EINTR => continue,
                    else => unreachable,
                }
            }
        }
    },
    .windows => struct {
        pub fn init(self: *@This()) void {}
        pub fn deinit(self: *@This()) void {}

        pub fn notify(self: *@This(), ptr: *u32, wakeup_count: i32) void {
            const addr = @ptrCast(system.LPVOID, ptr);
            switch (wakeup_count) {
                1 => WakeByAddressSingle(addr),
                else => WakeByAddressAll(addr),
            }
        }

        pub fn wait(self: *@This(), ptr: *u32, expect: u32, timeout_ms: ?u32) Futex.WaitError!void {
            var compare = expect;
            const addr = @ptrCast(system.LPVOID, ptr);
            const compare_addr = @ptrCast(system.LPVOID, &compare);

            if (WaitOnAddress(addr, compare_addr, @sizeOf(@typeOf(expect)), timeout_ms orelse system.INFINITE) == system.TRUE)
                return;
            return switch (system.kernel32.GetLastError()) {
                ERROR_TIMEOUT => Futex.WaitError.TimedOut,
                else => unreachable,
            };
        }

        extern "Synchronization" stdcallcc fn WakeByAddressAll(Address: system.LPVOID) void;
        extern "Synchronization" stdcallcc fn WakeByAddressSingle(Address: system.LPVOID) void;
        extern "Synchronization" stdcallcc fn WaitOnAddress(
            Address: system.LPVOID,
            CompareAddress: system.LPVOID,
            AddressSize: system.SIZE_T,
            dwMilliseconds: system.DWORD,
        ) system.BOOL;
    },
    else => struct {
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

        pub fn notify(self: *@This(), ptr: *u32, wakeup_count: i32) void {
            std.debug.assert(switch (wakeup_count) {
                1 => system.pthread_cond_signal(&self.cond),
                else => system.pthread_cond_broadcast(&self.cond),
            } == 0);
        }

        pub fn wait(self: *@This(), ptr: *u32, expect: u32, timeout_ms: ?u32) Futex.WaitError!void {
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
    },
};
