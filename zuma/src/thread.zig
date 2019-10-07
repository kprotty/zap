const std = @import("std");
const expect = std.testing.expect;
const zync = @import("../../zap.zig").zync;
const zuma = @import("../../zap.zig").zuma;

pub const ClockType = enum {
    Monotonic,
    Realtime,
};

pub const Thread = struct {
    inner: zuma.backend.Thread,

    pub threadlocal var Random = zync.Lazy(createThreadLocalRandom).new();
    fn createThreadLocalRandom() std.rand.DefaultPrng {
        const seed = now(.Monotonic) ^ u64(@ptrToInt(&Random));
        return std.rand.DefaultPrng.init(seed);
    }

    /// NOTE: Because of linux VDSO shenanigans (https://marcan.st/2017/12/debugging-an-evil-go-runtime-bug/)
    ///      One should ensure that the stack of this function call has at least 1-2 pages of owned memory.
    pub fn now(clock_type: ClockType) u64 {
        return zuma.backend.Thread.now(clock_type == .Monotonic);
    }

    pub fn sleep(ms: u32) void {
        return zuma.backend.Thread.sleep(ms);
    }

    pub fn yield() void {
        return zuma.backend.Thread.yield();
    }

    pub fn getStackSize(comptime function: var) usize {
        return zuma.backend.Thread.getStackSize(function);
    }

    pub const SpawnError = error{
        OutOfMemory,
        InvalidStack,
        TooManyThreads,
    };

    pub fn spawn(stack: ?[]align(zuma.mem.page_size) u8, comptime function: var, parameter: var) SpawnError!@This() {
        if (@sizeOf(@typeOf(parameter)) != @sizeOf(usize))
            @compileError("Parameter can only be a pointer sized value");
        return @This(){ .inner = try zuma.backend.Thread.spawn(stack, function, parameter) };
    }

    pub fn join(self: *@This(), timeout_ms: ?u32) void {
        return self.inner.join(timeout_ms);
    }

    pub const AffinityError = error{
        InvalidState,
        InvalidCpuAffinity,
    };

    pub fn setAffinity(cpu_affinity: zuma.CpuAffinity) AffinityError!void {
        return zuma.backend.Thread.setAffinity(cpu_affinity);
    }

    pub fn getAffinity(cpu_affinity: *zuma.CpuAffinity) AffinityError!void {
        return zuma.backend.Thread.getAffinity(cpu_affinity);
    }
};

test "Thread - random, now, sleep" {
    expect(Thread.Random.getPtr().random.uintAtMostBiased(usize, 10) <= 10);
    expect(Thread.now(.Realtime) > 0);

    const delay_ms = 200;
    const threshold_ms = 200;

    const now = Thread.now(.Monotonic);
    Thread.sleep(delay_ms);
    const elapsed = Thread.now(.Monotonic) - now;
    expect(elapsed >= delay_ms and elapsed < delay_ms + threshold_ms);
}

test "Thread - getAffinity, setAffinity" {
    // get the current thread affinity & count
    var cpu_affinity: zuma.CpuAffinity = undefined;
    cpu_affinity.clear();
    try Thread.getAffinity(&cpu_affinity);
    const cpu_count = cpu_affinity.count();
    expect(cpu_count > 0);

    // update the thread affinity to be only the first core
    var new_cpu_affinity: zuma.CpuAffinity = undefined;
    new_cpu_affinity.clear();
    new_cpu_affinity.set(0, true);
    try Thread.setAffinity(new_cpu_affinity);

    // check if the thread affinity truly is only the first core
    new_cpu_affinity.clear();
    try Thread.getAffinity(&new_cpu_affinity);
    expect(new_cpu_affinity.count() == 1);
    expect(new_cpu_affinity.get(0) == true);

    // set the affinity back to normal & check that its back to normal
    try Thread.setAffinity(cpu_affinity);
    cpu_affinity.clear();
    try Thread.getAffinity(&cpu_affinity);
    expect(cpu_affinity.count() == cpu_count);
}

test "Thread - getStackSize, spawn, yield" {
    const ThreadTest = struct {
        value: zync.Atomic(usize),

        fn update(self: *@This()) void {
            _ = self.value.fetchAdd(1, .Relaxed);
        }

        pub fn run(self: *@This()) !void {
            self.value.set(0);
            expect(self.value.get() == 0);

            var update_thread = thread: {
                const stack_size = Thread.getStackSize(update);
                if (stack_size > 0) {
                    var memory: [zuma.mem.page_size]u8 align(zuma.mem.page_size) = undefined;
                    expect(stack_size <= memory.len);
                    break :thread (try Thread.spawn(memory[0..], update, self));
                } else {
                    break :thread (try Thread.spawn(null, update, self));
                }
            };

            Thread.yield();
            update_thread.join(500);
            expect(self.value.load(.Relaxed) == 1);
        }
    };

    var thread_test: ThreadTest = undefined;
    try thread_test.run();
}
