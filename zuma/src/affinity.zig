const std = @import("std");
const expect = std.testing.expect;

const zync = @import("../../zap.zig").zync;
const zuma = @import("../../zap.zig").zuma;

pub const CpuType = enum {
    Physical,
    Logical,
};

pub const CpuAffinity = struct {
    const Index = zync.ShrType(usize);

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

test "CpuAffinity" {
    var cpu_affinity: CpuAffinity = undefined;
    cpu_affinity.clear();
    expect(cpu_affinity.count() == 0);

    cpu_affinity.set(1, true);
    expect(cpu_affinity.count() == 1);
    expect(cpu_affinity.get(1) == true);

    cpu_affinity.set(5, true);
    expect(cpu_affinity.count() == 2);
    expect(cpu_affinity.get(5) == true);
    expect(cpu_affinity.get(3) == false);

    const logical_cpu_count = try CpuAffinity.getCpuCount(null, .Logical);
    expect(logical_cpu_count > 0);
    const physical_cpu_count = try CpuAffinity.getCpuCount(null, .Physical);
    expect(physical_cpu_count > 0 and physical_cpu_count <= logical_cpu_count);

    var node_count = CpuAffinity.getNodeCount();
    expect(node_count > 0);
    while (node_count > 0) : (node_count -= 1) {
        cpu_affinity.clear();
        try cpu_affinity.getCpus(node_count - 1, .Logical);
        const logical_node_count = cpu_affinity.count();
        expect(logical_node_count > 0);

        cpu_affinity.clear();
        try cpu_affinity.getCpus(node_count - 1, .Physical);
        const physical_node_count = cpu_affinity.count();
        expect(physical_node_count > 0 and physical_node_count <= logical_node_count);
    }
}
