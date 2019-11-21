const std = @import("std");
const system = @import("../system.zig");

pub fn nanotime() u64 {

}

pub fn map(numa_node: u32, bytes: usize) system.MapError![]align(std.mem.page_size) u8 {
    
}

pub fn unmap(memory: []align(std.mem.page_size) u8) void {
    
}

pub const Affinity = struct {
    pub fn getNodeCount() usize {
        return 0;
    }

    pub fn getNodeAffinity(numa_node: u32) system.Affinity.Error!system.Affinity {
        return undefined;
    }
};

pub const Thread = struct {
    pub const USES_CUSTOM_STACKS = true;

    tid: *i32,

    pub fn join(self: Thread) void {

    }

    pub fn exit(self: Thread) void {

    }

    pub fn setAffinity(self: Thread, group: usize, mask: usize) system.Thread.AffinityError!void {
        return {};
    }

    pub fn spawn(stack: ?[]u8, size_hint: usize, param: var, comptime entry: var) system.Thread.SpawnError!Thread {
        return undefined;
    }
};