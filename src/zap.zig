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
        .macosx, .ios, .watchos, .tvos => true,
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
    pub const Task = @import("./task.zig").Task;

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

    pub const sync = struct {
        pub const atomic = core.sync.atomic;

        // pub const AsyncFutex = @import("./runtime/futex.zig").Futex;
        // pub const Futex = 
        //     if (is_windows) @import("./runtime/windows/futex.zig").Futex
        //     else if (is_posix) @import("./runtime/posix/futex.zig").Futex
        //     else if (is_linux) @import("./runtime/linux/futex.zig").Futex
        //     else @compileError("OS not supported for thread blocking/unblocking");
        
        pub const Futex = struct {
            event: std.AutoResetEvent = std.AutoResetEvent{},

            pub const Timestamp = u64;

            pub fn wait(self: *Futex, deadline: ?*Timestamp, condition: *core.sync.Condition) bool {
                if (!condition.isMet())
                    self.event.wait();
                return true;
            }

            pub fn wake(self: *Futex) void {
                self.event.set();
            }

            pub fn yield(self: *Futex, iteration: ?usize) bool {
                var iter = iteration orelse {
                    std.os.sched_yield() catch unreachable;
                    return false;
                };

                if (iter <= 3) {
                    while (iter != 0) : (iter -= 1)
                        yieldCpu();
                } else {
                    std.os.sched_yield() catch unreachable;
                }

                return true;
            }
        };

        pub fn yieldCpu() void {
            atomic.spinLoopHint();
        }

        pub fn yieldThread() void {
            Futex.yield(null);
        }

        pub const Lock = extern struct {
            lock: core.sync.Lock = core.sync.Lock{},

            pub fn acquire(self: *Lock) void {
                self.lock.acquire(Futex);
            }

            pub fn acquireAsync(self: *Lock) void {
                self.lock.acquire(AsyncFutex);
            }

            pub fn release(self: *Lock) void {
                self.lock.release();
            }
        };

        pub const AutoResetEvent = extern struct {
            event: core.sync.AutoResetEvent = core.sync.AutoResetEvent{},

            pub fn wait(self: *AutoResetEvent) void {
                self.event.wait(Futex);
            }

            pub fn waitAsync(self: *AutoResetEvent) void {
                self.event.wait(AsyncFutex);
            }

            pub fn timedWait(self: *AutoResetEvent) error{TimedOut}!void {
                self.event.timedWait(Futex);
            }

            pub fn timedWaitAsync(self: *AutoResetEvent) error{TimedOut}!void {
                self.event.timedWait(AsyncFutex);
            }

            pub fn set(self: *AutoResetEvent) void {
                self.event.set();
            }
        };
    };
};
