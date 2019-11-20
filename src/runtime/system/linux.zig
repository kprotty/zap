const std = @import("std");
const system = @import("../system.zig");

pub fn nanotime() u64 {

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

    pub fn spawn(stack: ?[]u8, size_hint: usize, param: var, comptime entry: var) !Thread {
        return undefined;
    }
};