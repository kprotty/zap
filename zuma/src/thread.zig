const std = @import("std");
const zuma = @import("../zuma.zig");

pub fn getNumaNodeCount() usize {
    return zuma.backend.getNumaNodeCount();
}

pub const CpuType = enum { Physical, Logical };
pub fn getCpuCoreCount(cpu_type: CpuType) usize {
    return zuma.backend.getCpuCoreCount(cpu_type == .Physical);
}

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
};

