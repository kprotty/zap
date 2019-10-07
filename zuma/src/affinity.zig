const std = @import("std");
const expect = std.testing.expect;

const zync = @import("../../zap.zig").zync;
const zuma = @import("../../zap.zig").zuma;

pub const CpuType = enum {
    Physical,
    Logical,
};

pub const CpuAffinity = struct {
    const Index = zync.shrType(usize);

    group: usize,
    mask: usize,

    pub fn clear(self: *@This()) void {
        self.group = 0;
        self.mask = 0;
    }

    pub fn count(self: @This()) usize {
        return zync.popCount(self.mask);
    }

    pub fn get(self: @This(), cpu: Index) bool {
        return (self.mask & (usize(1) << cpu)) != 0;
    }

    pub fn set(self: *@This(), cpu: Index, value: bool) void {
        if (value) {
            self.mask |= usize(1) << cpu;
        } else {
            self.mask &= ~(usize(1) << cpu);
        }
    }

    pub const TopologyError = zuma.NumaError;

    pub fn getNodeCount() usize {
        return zuma.backend.CpuAffinity.getNodeCount();
    }

    pub fn getCpuCount(numa_node: ?usize, cpu_type: CpuType) TopologyError!usize {
        return zuma.backend.CpuAffinity.getCpuCount(numa_node, cpu_type == .Physical);
    }

    pub fn getCpus(self: *@This(), numa_node: ?usize, cpu_type: CpuType) TopologyError!void {
        return zuma.backend.CpuAffinity.getCpus(self, numa_node, cpu_type == .Physical);
    }
};
