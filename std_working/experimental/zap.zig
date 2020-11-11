
pub const core = @import("real_zap").core;

pub const runtime = struct {
    const e = @import("./e4.zig");

    pub const Task = e.Task;

    pub const sync = struct {
        pub const atomic = core.sync.atomic;
        pub const Lock = e.Lock;

        pub const OsFutex = struct {
            pub const Timestamp = struct {
                nanos: u64 = 0,

                const std = @import("std");
                
                // var has_timer = false;
                // var timer: std.time.Timer = undefined;
                // var timer_lock = std.Mutex{};

                // pub fn getTimer() *std.time.Timer {
                //     if (@atomicLoad(bool, &has_timer, .Acquire))
                //         return &timer;
                //     return getTimerSlow();
                // }

                // fn getTimerSlow() *std.time.Timer {
                //     @setCold(true);

                //     const held = timer_lock.acquire();
                //     defer held.release();

                //     if (!@atomicLoad(bool, &has_timer, .Monotonic)) {
                //         timer = std.time.Timer.start() catch unreachable;
                //         @atomicStore(bool, &has_timer, true, .Release);
                //     }

                //     return &timer;
                // }

                pub fn current(self: *Timestamp) void {
                    self.nanos = blk: {
                        if (std.builtin.os.tag == .windows) {
                            break :blk std.os.windows.QueryPerformanceCounter();
                        }

                        if (comptime std.Target.current.isDarwin()) {
                            break :blk std.os.darwin.mach_absolute_time();
                        }

                        var ts: std.os.timespec = undefined;
                        std.os.clock_gettime(std.os.CLOCK_MONOTONIC, &ts) catch unreachable;
                        break :blk @intCast(u64, ts.tv_sec) * @as(u64, std.time.ns_per_s) + @intCast(u64, ts.tv_nsec);
                    };
                }
            };
        };
    };
};