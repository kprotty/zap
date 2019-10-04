const std = @import("std");
const expect = std.testing.expect;
const zuma = @import("../zuma.zig");
const zync = @import("../../zap.zig").zync;

pub const CpuType = enum { 
    Physical,
    Logical,
};

pub const CpuSet = struct {
    inner: zuma.backend.CpuSet,

    pub fn clear(self: *@This()) void {
        std.mem.secureZero(@This(), @ptrCast([*]@This(), self)[0..1]);
    }

    pub const IndexError = error {
        InvalidCpu,
    };

    pub fn set(self: *@This(), index: usize, value: bool) IndexError!void {
        return self.inner.set(index, value);
    }

    pub fn get(self: @This(), index: usize) IndexError!bool {
        return self.inner.get(index);
    }

    pub fn count(self: @This()) usize {
        return self.inner.count();
    }

    pub const NodeError = error {
        InvalidNode,
        SystemResourceAccess,
    };

    pub fn getNodeCount() usize {
        return zuma.backend.CpuSet.getNodeCount();
    }

    pub fn getNodeSize(numa_node: usize) NodeError!usize {
        return zuma.backend.CpuSet.getNodeSize(numa_node);
    }

    pub const CpuError = IndexError || NodeError;

    pub fn getCpus(self: *@This(), numa_node: ?usize, cpu_type: CpuType) CpuError!void {
        return self.inner.getCpus(numa_node, cpu_type == .Physical);
    }
};

test "CpuSet" {
    // test basic cpu_set functionality
    var cpu_set: CpuSet = undefined;
    cpu_set.clear();
    try cpu_set.set(1, true);
    expect(cpu_set.count() == 1);
    expect((try cpu_set.get(1)) == true);
    try cpu_set.set(1, false);
    expect((try cpu_set.get(1)) == false);

    // test fetching logical cpus
    try cpu_set.getCpus(null, .Logical);
    const logical_count = cpu_set.count();
    expect(logical_count > 0);
    cpu_set.clear();

    // test fetching physical cpus
    try cpu_set.getCpus(null, .Physical);
    const physical_count = cpu_set.count();
    expect(physical_count <= logical_count);
    cpu_set.clear();
    
    // test fetching invalid numa nodes
    if (cpu_set.getCpus(999999, .Logical)) |_| unreachable
    else |err| switch (err) {
        CpuSet.NodeError.InvalidNode => expect(cpu_set.count() == 0),
        else => return err,
    }

    // test fetching numa node count & node memory size
    expect(CpuSet.getNodeCount() > 0);
    expect((try CpuSet.getNodeSize(0)) > 0);

    // test fetching invalid numa node memory size
    if (CpuSet.getNodeSize(999999)) |_| unreachable
    else |err| switch (err) {
        CpuSet.NodeError.InvalidNode => {},
        else => return err,
    }
}

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

    // NOTE: Because of linux VDSO shenanigans (https://marcan.st/2017/12/debugging-an-evil-go-runtime-bug/)
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

    pub fn spawn(stack: ?[]align(zuma.mem.page_size) u8, comptime function: var, parameter: var) SpawnError!@This() {
        if (@sizeOf(parameter) != @sizeOf(usize))
            @compileError("Parameter can only be a pointer sized value");
        return @This() { .inner = zuma.backend.Thread.spawn(stack, function, parameter) };
    }

    pub fn join(self: *@This(), timeout_ms: ?u32) void {
        return self.inner.join(timeout_ms);
    }

    pub const AffinityError = error {
        InvalidState,
        InvalidCpuSet,
    };

    pub fn setCurrentAffinity(cpu_set: *const CpuSet) AffinityError!void {
        return zuma.backend.Thread.setCurrentAffinity(&cpu_set.inner);
    }

    pub fn getCurrentAffinity(cpu_set: *CpuSet) AffinityError!void {
        return zuma.backend.Thread.getCurrentAffinity(&cpu_set.inner);
    }
};

