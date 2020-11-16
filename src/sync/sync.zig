const builtin = @import("builtin");

pub const core = struct {
    pub const arch_type = builtin.arch;

    pub const is_x86 = switch (arch_type) {
        .i386, .x86_64 => true,
        else => false,
    };

    pub const is_arm = switch (arch_type) {
        .arm, .aarch64 => true,
        else => false,
    };

    pub const atomic = @import("./atomic.zig");
    pub const Lock = @import("./lock.zig").Lock;
};


pub const WaitGroup = @import("./wait_group.zig").WaitGroup;
