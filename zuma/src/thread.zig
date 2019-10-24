const std = @import("std");
const expect = std.testing.expect;
const expectError = std.testing.expectError;

const zync = @import("../../zap.zig").zync;
const zuma = @import("../../zap.zig").zuma;

pub const ClockType = enum {
    Monotonic,
    Realtime,
};

pub const Thread = struct {
    pub const Handle = zuma.backend.Thread.Handle;

    threadlocal var random_instance = zync.Lazy(createThreadLocalRandom).new();
    fn createThreadLocalRandom() std.rand.DefaultPrng {
        const seed = now(.Monotonic) ^ u64(@ptrToInt(&random_instance));
        return std.rand.DefaultPrng.init(seed);
    }

    pub fn getRandom() *std.rand.Random {
        return &random_instance.getPtr().random;
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

    pub const CreateError = std.os.UnexpectedError || error{
        OutOfMemory,
        InvalidStack,
        TooManyThreads,
    };

    pub fn create(stack: ?[]align(zuma.page_size) u8, comptime function: var, parameter: var) CreateError!Handle {
        if (@sizeOf(@typeOf(parameter)) != @sizeOf(usize))
            @compileError("Parameter can only be a pointer sized value");
        return zuma.backend.Thread.create(stack, function, parameter);
    }

    pub fn spawn(comptime function: var, parameter: var) CreateError!JoinHandle {
        var join_handle: JoinHandle = undefined;
        join_handle.memory = null;

        const stack_size = getStackSize(function);
        if (stack_size > 0) {
            const flags = zuma.PAGE_READ | zuma.PAGE_WRITE | zuma.PAGE_COMMIT;
            join_handle.memory = zuma.map(null, stack_size, flags, null) catch |err| switch (err) {
                zuma.MemoryError.OutOfMemory => return CreateError.OutOfMemory,
                zuma.MemoryError.Unexpected => return CreateError.Unexpected,
                else => unreachable,
            };
        }

        join_handle.handle = try create(join_handle.memory, function, parameter);
        return join_handle;
    }

    pub const JoinHandle = struct {
        handle: ?Handle,
        memory: ?[]align(zuma.page_size) u8,

        pub fn join(self: *@This(), timeout_ms: ?u32) JoinError!void {
            const handle = self.handle orelse return;
            try zuma.backend.Thread.join(handle, timeout_ms);
            if (self.memory) |memory|
                zuma.unmap(memory, null);
            self.memory = null;
            self.handle = null;
        }
    };

    pub const JoinError = error{TimedOut};

    pub fn join(handle: Handle, timeout_ms: ?u32) JoinError!void {
        return self.inner.join(handle, timeout_ms);
    }

    pub const AffinityError = std.os.UnexpectedError || error{
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
    expect(Thread.getRandom().uintAtMostBiased(usize, 10) <= 10);
    expect(Thread.now(.Realtime) > 0);

    const delay_ms = 200;
    const threshold_ms = 300;
    const max_delay = delay_ms + threshold_ms;
    const min_delay = delay_ms - std.math.min(delay_ms, threshold_ms);

    const now = Thread.now(.Monotonic);
    Thread.sleep(delay_ms);
    const elapsed = Thread.now(.Monotonic) - now;
    expect(elapsed > min_delay and elapsed < max_delay);
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
    const delay_ms = 200;
    const threshold_ms = 800;
    const max_delay = delay_ms + threshold_ms;
    const min_delay = delay_ms - std.math.min(delay_ms, threshold_ms);

    const ThreadTest = struct {
        pub fn update(item: *zync.Atomic(usize)) void {
            _ = item.fetchAdd(1, .Relaxed);
        }

        pub fn updateDelayed(item: *zync.Atomic(usize)) void {
            Thread.sleep(delay_ms);
            update(item);
        }
    };

    var value = zync.Atomic(usize).new(0);
    expect(value.get() == 0);

    // test thread creation + joining
    var thread = try Thread.spawn(ThreadTest.update, &value);
    try thread.join(500);
    expect(value.load(.Relaxed) == 1);

    // test thread join timeout + rejoining
    var delayed_thread = try Thread.spawn(ThreadTest.updateDelayed, &value);
    const now = Thread.now(.Monotonic);
    expectError(Thread.JoinError.TimedOut, delayed_thread.join(1));
    try delayed_thread.join(500);
    expect(value.load(.Relaxed) == 2);
    const elapsed = Thread.now(.Monotonic) - now;
    expect(elapsed > min_delay and elapsed < max_delay);
}
