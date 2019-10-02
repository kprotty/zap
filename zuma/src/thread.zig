const std = @import("std");
const zuma = @import("zuma");

pub const CpuType = enum { 
    Physical,
    Logical,
};

pub const CpuSet = struct {
    inner: zuma.backend.CpuSet,

    pub fn clear(self: *@This()) void {
        std.mem.secureZero(@This(), @ptrCast([*]@This(), self)[0..1]);
    }

    pub fn set(self: *@This(), index: usize, value: bool) ?void {
        return self.inner.set(index, value);
    }

    pub fn get(self: @This(), index: usize) ?bool {
        return self.inner.get(index);
    }

    pub fn size(self: @This()) usize {
        return self.inner.size();
    }

    pub fn getCpus(self: *@This(), numa_node: ?usize, cpu_type: CpuType) void {
        return self.inner.getCpus(numa_node, cpu_type == .Physical);
    }

    pub fn getNodeCount() usize {
        return self.inner.getNodeCount();
    }
};

pub const Thread = struct {
    inner: zuma.backend.Thread,

    // NOTE: Because of linux VDSO shenanigans (https://marcan.st/2017/12/debugging-an-evil-go-runtime-bug/)
    ///      One should ensure that the stack of this function call has at least 1-2 pages of owned memory.
    pub const ClockTime = enum { Monotonic, Realtime };
    pub fn now(clock_time: ClockTime) u64 {
        return zuma.backend.Thread.now(clock_time == .Monotonic);
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

