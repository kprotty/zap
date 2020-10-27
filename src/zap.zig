const std = @import("std");

pub const core = struct {
    pub const sync = @import("./core/sync.zig");
    pub const executor = @import("./core/executor.zig");

    pub const os_tag = std.builtin.os.tag;
    pub const arch_tag = std.builtin.arch;
    pub const link_libc = std.builtin.link_libc;

    pub const is_x86 = switch (arch_tag) {
        .i386, .x86_64 => true,
        else => false,
    };
    pub const is_arm = switch (arch_tag) {
        .arm, .aarch64 => true,
        else => false,
    };

    pub const is_linux = os_tag == .linux;
    pub const is_windows = os_tag == .windows;
    pub const is_darwin = switch (os_tag) {
        .macos, .ios, .watchos, .tvos => true,
        else => false,
    };
    pub const is_bsd = is_darwin or switch (os_tag) {
        .openbsd, .freebsd, .kfreebsd, .netbsd, .dragonfly => true,
        else => false,
    };
    pub const is_posix = link_libc and (is_linux or is_bsd or switch (os_tag) {
        .minix, .haiku, .hermit => true,
        else => false,
    });
};

pub const runtime = struct {
    pub const sync = @import("./runtime/sync.zig");
    pub const Task = @import("./runtime/task.zig").Task;

    // pub const Thread =
    //     if (is_windows) @import("./runtime/windows/thread.zig").Thread
    //     else if (is_posix) @import("./runtime/posix/thread.zig").Thread
    //     else if (is_linux) @import("./runtime/linux/thread.zig").Thread
    //     else @compileError("OS not supported for thread spawning/joining");

    pub const Thread = struct {
        pub const Handle = *std.Thread;

        pub fn cpuCount() usize {
            return std.Thread.cpuCount() catch 1;
        }

        pub fn spawn(parameter: usize, comptime entryFn: anytype) bool {
            const Spawner = struct {
                param: usize,
                handle: Handle = undefined,
                thread_event: std.AutoResetEvent = std.AutoResetEvent{},
                spawner_event: std.AutoResetEvent = std.AutoResetEvent{},

                fn entry(spawner: *@This()) void {
                    const param = spawner.param;
                    spawner.thread_event.wait();

                    const handle = spawner.handle;
                    spawner.spawner_event.set();

                    entryFn(handle, param);
                }
            };

            var spawner = Spawner{ .param = parameter };
            if (std.Thread.spawn(&spawner, Spawner.entry)) |handle| {
                spawner.handle = handle;
                spawner.thread_event.set();
                spawner.spawner_event.wait();
                return true;
            } else |err| {
                return false;
            }
        }

        pub fn join(handle: Handle) void {
            handle.wait();
        }
    };
};
