const std = @import("std");

pub const Futex = if (std.builtin.os.tag == .windows)
    WindowsFutex
else if (std.builtin.os.tag == .linux)
    LinuxFutex
else if (std.Target.current.isDarwin())
    DarwinFutex
else if (std.builtin.link_libc)
    PosixFutex
else 
    @compileError("Platform not supported");

const DarwinFutex = struct {
    pub fn wait(ptr: *const u32, expected: u32, timeout: ?u64) callconv(.Inline) error{TimedOut}!void {
        return PosixFutex.wait(ptr, expected, timeout);
    }

    pub fn wake(ptr: *const u32, waiters: u32) callconv(.Inline) void {
        return PosixFutex.wake(ptr, waiters);
    }

    pub fn yield(iteration: usize) bool {
        if (std.builtin.arch != .x86_64) return false;
        if (iteration > 100) return false;
        std.atomic.spinLoopHint();
        return true;
    }
};

const WindowsFutex = struct {
    extern "NtDll" fn RtlWakeAddressAll(
        Address: ?*const c_void,
    ) callconv(std.os.windows.WINAPI) void;

    extern "NtDll" fn RtlWakeAddressSingle(
        Address: ?*const c_void,
    ) callconv(std.os.windows.WINAPI) void;

    extern "NtDll" fn RtlWaitOnAddress(
        Address: ?*const c_void,
        CompareAddress: ?*const c_void,
        AddressSize: std.os.windows.SIZE_T,
        Timeout: ?*const std.os.windows.LARGE_INTEGER,
    ) callconv(std.os.windows.WINAPI) std.os.windows.NTSTATUS;

    pub fn wait(ptr: *const u32, expected: u32, timeout: ?u64) error{TimedOut}!void {
        var timeout_val: std.os.windows.LARGE_INTEGER = undefined;
        var timeout_ptr: ?*const @TypeOf(timeout_val) = null;
        if (timeout) |timeout_ns| {
            timeout_ptr = &timeout_val;
            timeout_val = -@intCast(@TypeOf(timeout_val), timeout_ns / 100);
        }

        const status = RtlWaitOnAddress(
            @ptrCast(?*const c_void, ptr),
            @ptrCast(?*const c_void, &expected),
            @sizeOf(@TypeOf(expected)),
            timeout_ptr,
        );

        if (status == .TIMEOUT)
            return error.TimedOut;
    }

    pub fn wake(ptr: *const u32, waiters: u32) void {
        const address = @ptrCast(?*const c_void, ptr);
        switch (waiters) {
            0 => {},
            1 => RtlWakeAddressSingle(address),
            else => RtlWakeAddressAll(address),
        }
    }

    pub fn yield(iteration: usize) bool {
        if (iteration >= 4000) return false;
        std.atomic.spinLoopHint();
        return true;
    }
};

const LinuxFutex = struct {
    pub fn wait(ptr: *const u32, expected: u32, timeout: ?u64) error{TimedOut}!void {
        var ts: std.os.timespec = undefined;
        var ts_ptr: ?*std.os.timespec = null;
        if (timeout) |timeout_ns| {
            ts_ptr = &ts;
            ts.tv_sec = std.math.cast(@TypeOf(ts.tv_sec), timeout_ns / std.time.ns_per_s) catch std.math.maxInt(@TypeOf(ts.tv_sec));
            ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), timeout_ns % std.time.ns_per_s);
        }
        
        switch (std.os.linux.getErrno(std.os.linux.futex_wait(
            @ptrCast(*const i32, ptr),
            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAIT,
            @bitCast(i32, expected),
            ts_ptr,
        ))) {
            0 => {},
            std.os.EINTR => {},
            std.os.EAGAIN => {},
            std.os.ETIMEDOUT => return error.TimedOut,
            else => unreachable,
        }
    }

    pub fn wake(ptr: *const u32, waiters: u32) void {
        switch (std.os.linux.getErrno(std.os.linux.futex_wake(
            @ptrCast(*const i32, ptr),
            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAKE,
            std.math.cast(i32, waiters) catch std.math.maxInt(i32),
        ))) {
            0 => {},
            std.os.EINVAL => {},
            std.os.EACCES => {},
            std.os.EFAULT => {},
            else => unreachable,
        }
    }

    pub fn yield(iteration: usize) bool {
        if (iteration > 10) return false;
        std.atomic.spinLoopHint();
        return true;
    }
};

const PosixFutex = GenericFutex(struct {
    state: State = .empty,
    cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    const State = enum{
        empty,
        waiting,
        notified,
    };

    pub fn init(self: *@This()) void {
        self.* = .{};
    }

    pub fn deinit(self: *@This()) void {
        const rc = std.c.pthread_cond_destroy(&self.cond);
        std.debug.assert(rc == 0 or rc == std.os.EINVAL);

        const rm = std.c.pthread_mutex_destroy(&self.mutex);
        std.debug.assert(rm == 0 or rm == std.os.EINVAL);

        self.* = undefined;
    }

    pub fn set(self: *@This()) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

        const state = self.state;
        self.state = .notified;
        switch (state) {
            .empty => {},
            .waiting => std.debug.assert(std.c.pthread_cond_signal(&self.cond) == 0),
            .notified => unreachable,
        }
    }

    pub fn wait(self: *@This(), timeout: ?u64) error{TimedOut}!void {
        var deadline: ?u64 = null;
        if (timeout) |timeout_ns|
            deadline = timestamp(std.os.CLOCK_MONOTONIC, timeout_ns);

        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

        switch (self.state) {
            .empty => self.state = .waiting,
            .waiting => unreachable,
            .notified => return,
        }

        while (true) {
            switch (self.state) {
                .empty => unreachable,
                .waiting => {},
                .notified => return,
            }

            const deadline_ns = deadline orelse {
                std.debug.assert(std.c.pthread_cond_wait(&self.cond, &self.mutex) == 0);
                continue;
            };

            var ns = timestamp(std.os.CLOCK_MONOTONIC, 0);
            if (ns > deadline_ns) {
                self.state = .empty;
                return error.TimedOut;
            } else {
                ns = timestamp(std.os.CLOCK_REALTIME, deadline_ns - ns);
            }

            var ts: std.os.timespec = undefined;
            ts.tv_sec = std.math.cast(@TypeOf(ts.tv_sec), ns / std.time.ns_per_s) catch std.math.maxInt(@TypeOf(ts.tv_sec));
            ts.tv_nsec = std.math.cast(@TypeOf(ts.tv_nsec), ns % std.time.ns_per_s) catch std.time.ns_per_s;
            
            switch (std.c.pthread_cond_timedwait(&self.cond, &self.mutex, &ts)) {
                0 => {},
                std.os.ETIMEDOUT => {},
                else => unreachable,
            }
        }
    }

    pub fn yield(iteration: usize) bool {
        if (iteration > 40)
            return false;

        std.os.sched_yield() catch {};
        return true;
    }

    fn timestamp(comptime clock: u32, offset: u64) u64{
        var now: u64 = undefined;
        if (std.Target.current.isDarwin()) {
            switch (clock) {
                std.os.CLOCK_REALTIME => {
                    var tv: std.os.timeval = undefined;
                    std.os.gettimeofday(&tv, null);
                    now = @intCast(u64, tv.tv_sec) * std.time.ns_per_s;
                    now += @intCast(u64, tv.tv_usec) * std.time.ns_per_us;
                },
                std.os.CLOCK_MONOTONIC => {
                    var freq: std.os.darwin.mach_timebase_info_data = undefined;
                    std.os.darwin.mach_timebase_info(&freq);
                    now = std.os.darwin.mach_absolute_time();
                    if (freq.numer > 1) now *= freq.numer;
                    if (freq.denom > 1) now /= freq.denom;
                },
                else => unreachable,
            }
        } else {
            var ts: std.os.timespec = undefined;
            std.os.clock_gettime(clock, &ts) catch {
                ts.tv_sec = std.math.maxInt(@TypeOf(ts.tv_sec));
                ts.tv_nsec = std.time.ns_per_s - 1;
            };
            now = @intCast(u64, ts.tv_sec) * std.time.ns_per_s;
            now += @intCast(u64, ts.tv_nsec);
        }
        
        var ns = now;
        if (@addWithOverflow(u64, now, offset, &ns))
            ns = std.math.maxInt(u64);
        return ns;
    }
});

fn GenericFutex(comptime EventImpl: type) type {
    return struct {
        pub const Event = EventImpl;
    
        const Waiter = struct {
            prev: ?*Waiter,
            next: ?*Waiter,
            address: usize,
            event: Event,
            waiting: bool,
        };

        const Bucket = struct {
            lock: @import("./Lock.zig").Lock = .{},
            head: ?*Waiter = null,
            tail: ?*Waiter = null,
            waiters: usize = 0,

            const num_buckets = 256;
            var buckets = [_]Bucket{.{}} ** num_buckets;

            fn from(address: usize) *Bucket {
                const seed = 0x9E3779B97F4A7C15 >> (64 - std.meta.bitCount(usize));
                const index = (address *% seed) % num_buckets;
                return &buckets[index];
            }

            fn push(self: *Bucket, waiter: *Waiter, address: usize) void {
                waiter.waiting = true;
                waiter.address = address;
                waiter.prev = self.tail;
                waiter.next = null;

                if (self.head == null) 
                    self.head = waiter;
                if (self.tail) |tail| 
                    tail.next = waiter;
                self.tail = waiter;
            }

            fn pop(self: *Bucket, address: usize, max: usize) ?*Waiter {
                var removed: usize = 0;
                var waiters: ?*Waiter = null;
                var iter = self.head;

                dequeue: while (removed < max) {
                    const waiter = blk: {
                        while (true) {
                            const waiter = iter orelse break :dequeue;
                            iter = waiter.next;
                            if (waiter.address != address) continue;
                            break :blk waiter;
                        }
                    };
                    self.remove(waiter);
                    removed += 1;
                    waiter.next = waiters;
                    waiters = waiter;
                }

                if (removed > 0)
                    _ = @atomicRmw(usize, &self.waiters, .Sub, removed, .SeqCst);
                return waiters;
            }

            fn remove(self: *Bucket, waiter: *Waiter) void {
                std.debug.assert(waiter.waiting);
                waiter.waiting = false;

                if (waiter.prev) |prev| 
                    prev.next = waiter.next;
                if (waiter.next) |next|
                    next.prev = waiter.prev;

                if (self.head == waiter) {
                    self.head = waiter.next;
                    if (self.head == null)
                        self.tail = null;
                } else if (self.tail == waiter) {
                    self.tail = waiter.prev;
                }
            }
        };  

        pub fn wait(ptr: *const u32, expected: u32, timeout: ?u64) error{TimedOut}!void {
            const address = @ptrToInt(ptr);
            const bucket = Bucket.from(address);
            bucket.lock.acquire();
            _ = @atomicRmw(usize, &bucket.waiters, .Add, 1, .SeqCst);

            if (@atomicLoad(u32, ptr, .SeqCst) != expected) {
                _ = @atomicRmw(usize, &bucket.waiters, .Sub, 1, .SeqCst);
                bucket.lock.release();
                return;
            }

            var waiter: Waiter = undefined;
            waiter.event.init();
            defer waiter.event.deinit();

            bucket.push(&waiter, address);
            bucket.lock.release();

            var timed_out = false;
            waiter.event.wait(timeout) catch {
                timed_out = true;
            };

            if (timed_out) {
                bucket.lock.acquire();
                if (waiter.waiting) {
                    _ = @atomicRmw(usize, &bucket.waiters, .Sub, 1, .SeqCst);
                    bucket.remove(&waiter);
                    bucket.lock.release();
                } else {
                    timed_out = false;
                    bucket.lock.release();
                    waiter.event.wait(null) catch unreachable;
                }
            }

            if (timed_out)
                return error.TimedOut;
        }

        pub fn wake(ptr: *const u32, waiters: u32) void {
            const address = @ptrToInt(ptr);
            const bucket = Bucket.from(address);

            if (@atomicLoad(usize, &bucket.waiters, .SeqCst) == 0)
                return;

            var pending = blk: {
                bucket.lock.acquire();
                defer bucket.lock.release();
                break :blk bucket.pop(address, waiters);
            };

            while (pending) |waiter| {
                pending = waiter.next;
                waiter.event.set();
            }
        }

        pub fn yield(iteration: usize) bool {
            return Event.yield(iteration);
        }
    };
}