const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os) {
    .windows => @import("system/windows.zig"),
    .linux => @import("system/linux.zig"),
    else => @import("system/posix.zig"),
};

pub fn nanotime() u64 {
    return backend.nanotime();
}

threadlocal var random_instance = std.lazyInit(std.rand.DefaultPrng);

pub fn getRandom() *std.rand.Random {
    return random_instance.get() orelse {
        const seed = @ptrToInt(&random_instance) ^ nanotime();
        random_instance.data = std.rand.DefaultPrng.init(seed);
        random_instance.resolve();
        return random_instance.data;
    };
}

pub const Affinity = struct {
    group: usize,
    mask: usize,

    pub const Error = error{

    };

    pub fn fromNode(numa_node: u32) Error!Affinity {
        return backend.Affinity.getNodeAffinity(numa_node);
    }

    pub fn getNodeCount() usize {
        return backend.Affinity.getNodeCount();
    }
};

pub const Thread = struct {
    pub const USES_CUSTOM_STACKS = backend.Thread.USES_CUSTOM_STACKS;
    
    inner: backend.Thread,

    pub fn join(self: Thread) void {
        return self.inner.join();
    }

    pub fn exit(self: Thread) void {
        return self.inner.exit();
    }

    pub fn spawn(stack: ?[]u8, size_hint: usize, param: var, comptime entry: var) SpawnError!Thread {
        return Thread{ .inner = try backend.Thread.spawn(stack, size_hint, param, entry) };
    }
};
