const std = @import("std");

pub usingnamespace if (std.builtin.os.tag == .windows)
    WindowsFutex
else if (std.builtin.os.tag == .linux)
    LinuxFutex
else if (std.Target.current.isDarwin())
    DarwinFutex
else if (std.builtin.link_libc)
    PosixFutex(struct {})
else 
    @compileError("Platform not supported");

const LinuxFutex = struct {
    pub fn wait(ptr: *const u32, expected: u32, timeout: ?u64) error{TimedOut}!void {
        var ts: std.os.timespec = undefined;
        var ts_ptr: ?*std.os.timespec = null;
        if (timeout) |timeout_ns| {
            ts_ptr = &ts;
            ts.tv_sec = timeout_ns / std.time.ns_per_s;
            ts.tv_nsec = timeout_ns % std.time.ns_per_s;
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
        if (iteration > 100)
            return false;

        std.Thread.spinLoopHint();
        return true;
    }
};

const DarwinFutex = PosixFutex(struct {
    pub const Lock = struct {
        oul: u32 = 0,

        pub fn acquire(self: *@This()) void {
            os_unfair_lock_lock(&self.oul);
        }

        pub fn release(self: *@This()) void {
            os_unfair_lock_unlock(&self.oul);
        }

        extern "c" fn os_unfair_lock_lock(oul: *u32) void;
        extern "c" fn os_unfair_lock_unlock(oul: *u32) void;
    };

    pub fn yield(iteration: usize) bool {
        if (std.builtin.os.tag != .macos)
            return false;

        const max_spin = switch (std.builtin.arch) {
            .x86_64 => 100,
            else => 10,
        };

        if (iteration > max_spin)
            return false;

        std.Thread.spinLoopHint();
        return true;
    }
});

fn PosixFutex(comptime Config: type) type {
    return GenericFutex(struct {
        pub const Lock = if (@hasDecl(Config, "Lock"))
            Config.Lock
        else
            struct {
                mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

                pub fn acquire(self: *@This()) void {
                    const rc = std.c.pthread_mutex_lock(&self.mutex);
                    std.debug.assert(rc == 0);
                }

                pub fn release(self: *@This()) void {
                    const rc = std.c.pthread_mutex_unlock(&self.mutex);
                    std.debug.assert(rc == 0);
                }
            };

        pub const Event = struct {
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
                defer std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);

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
                defer std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);

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
                if (@hasDecl(Config, "yield"))
                    return Config.yield(iteration);
                
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
        };
    });
}

const WindowsFutex = struct {
    pub fn wait(ptr: *const u32, expected: u32, timeout: ?u64) error{TimedOut}!void {
        if (WaitOnAddress.isSupported())
            return WaitOnAddress.wait(ptr, expected, timeout);
        return generic.wait(ptr, expected, timeout);
    }

    pub fn wake(ptr: *const u32, waiters: u32) void {
        if (WaitOnAddress.isSupported())
            return WaitOnAddress.wake(ptr, waiters);
        return generic.wake(ptr, waiters);
    }

    pub fn yield(iteration: usize) bool {
        return OsEvent.yield(iteration);
    }

    const generic = GenericFutex(struct {
        pub const Lock = OsLock;
        pub const Event = OsEvent;
    });

    const WaitOnAddress = struct {
        var state: State = .uninit;
        var wait_ptr: usize = undefined;
        var wake_one_ptr: usize = undefined;
        var wake_all_ptr: usize = undefined;

        const State = enum(u8) {
            uninit,
            supported,
            unsupported,
        };

        fn isSupported() bool {
            return switch (@atomicLoad(State, &state, .Acquire)) {
                .uninit => checkSupported(),
                .supported => true,
                .unsupported => false,
            };
        }

        fn checkSupported() bool {
            @setCold(true);

            @compileError("TODO");
        }

        fn wait(ptr: *const u32, expected: u32, timeout: ?u64) error{TimedOut}!void {
            @compileError("TODO");
        }

        fn wake(ptr: *const u32, waiters: u32) void {
            @compileError("TODO");
        }
    };

    const OsLock = struct {
        lock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

        pub fn acquire(self: *@This()) void {
            std.os.windows.kernel32.AcquireSRWLockExclusive(&self.lock);
        }

        pub fn release(self: *@This()) void {
            std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.lock);
        }
    };

    const OsEvent = struct {
        state: State = .empty,
        lock: OsLock = .{},
        cond: std.os.windows.CONDITION_VARIABLE = std.os.windows.CONDITION_VARIABLE_INIT,

        const State = enum {
            empty,
            waiting,
            notified,
        };

        pub fn init(self: *@This()) void {
            self.* = .{};
        }

        pub fn deinit(self: *@This()) void {
            self.* = undefined;
        }

        pub fn set(self: *@This()) void {
            self.lock.acquire();
            defer self.lock.release();

            const state = self.state;
            self.state = .notified;
            switch (state) {
                .empty => {},
                .waiting => std.os.windows.kernel32.WakeConditionVariable(&self.cond),
                .notified => unreachable,
            }
        }

        threadlocal var frequency: u64 = 0;

        pub fn wait(self: *@This(), timeout: ?u64) error{TimedOut}!void {
            var start: u64 = undefined;
            if (timeout != null) {
                if (frequency == 0) frequency = std.os.windows.QueryPerformanceFrequency();
                start = std.os.windows.QueryPerformanceCounter();
            }

            self.lock.acquire();
            defer self.lock.release();

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

                var timeout_ms: std.os.windows.DWORD = std.os.windows.INFINITE;
                if (timeout) |timeout_ns| {
                    const now = std.os.windows.QueryPerformanceCounter();
                    const elapsed = if (now < start) 0 else blk: {
                        const a = now - start;
                        const b = std.time.ns_per_s;
                        const c = frequency;
                        const q = a / c;
                        const r = a % c;
                        break :blk (q * b) + (r * b) / c;
                    };

                    if (elapsed > timeout_ns) {
                        self.state = .empty;
                        return error.TimedOut;
                    }

                    const delay_ms = (timeout_ns - elapsed) / std.time.ns_per_ms;
                    timeout_ms = std.math.cast(std.os.windows.DWORD, delay_ms) catch timeout_ms;
                }

                const status = std.os.windows.kernel32.SleepConditionVariableSRW(
                    &self.cond,
                    &self.lock.lock,
                    timeout_ms,
                    0,
                );

                if (status == std.os.windows.FALSE) {
                    switch (std.os.windows.kernel32.GetLastError()) {
                        .TIMEOUT => {},
                        else => |err| {
                            const e = std.os.windows.unexpectedError(err);
                            unreachable;
                        },
                    }
                }
            }
        }

        pub fn yield(iteration: usize) bool {
            if (iteration > 4000)
                return false;

            std.Thread.spinLoopHint();
            return true;
        }
    };
};

fn GenericFutex(comptime Config: type) type {
    const Lock = Config.Lock;
    const Event = Config.Event;

    return struct {
        const Waiter = struct {
            prev: ?*Waiter,
            next: ?*Waiter,
            address: usize,
            event: Event,
            waiting: bool,
        };

        const Bucket = struct {
            lock: Lock = .{},
            head: ?*Waiter = null,
            tail: ?*Waiter = null,
            waiters: usize = 0,

            const num_buckets = 256;
            var buckets = [_]Bucket{.{}} ** num_buckets;

            fn from(address: usize) *Bucket {
                const index = (address >> @sizeOf(u32)) % num_buckets;
                return &buckets[index];
            }

            fn push(self: *Bucket, waiter: *Waiter, address: usize) void {
                waiter.waiting = true;
                waiter.address = address;
                waiter.prev = self.tail;
                waiter.next = null;
                if (self.tail) |tail| tail.next = waiter;
                if (self.head == null) self.head = waiter;
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
                waiter.waiting = false;
                if (waiter.prev) |prev| prev.next = waiter.next;
                if (waiter.next) |next| next.prev = waiter.prev;
                if (self.tail == waiter) self.tail = waiter.prev;
                if (self.head == waiter) self.head = waiter.next;
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