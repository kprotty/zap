const std = @import("std");

pub const Task = @import("./task.zig").Task;

pub const sync = struct {
    pub const core = struct {
        pub fn spinLoopHint() void {
            switch (std.builtin.arch) {
                .i386, .x86_64 => asm volatile("pause"),
                .arm, .aarch64 => asm volatile("yield"),
                else => {},
            }
        }

        pub const Lock = @import("./sync/lock.zig").Lock;
    };

    pub const os = struct {
        pub const Signal = @import("./signal.zig").Signal;

        pub const Lock = core.Lock(Signal);
    };

    pub const task = struct {
        // TODO
    };
};