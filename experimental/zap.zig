
pub const core = @import("real_zap").core;

pub const runtime = struct {
    const e = @import("./e2.zig");

    pub const Task = e.Task;

    pub const sync = struct {
        pub const atomic = core.sync.atomic;
        pub const Lock = e.Lock;

        pub const OsFutex = struct {
            pub const Timestamp = struct {
                nanos: u64 = 0,

                pub fn current(self: *Timestamp) void {
                    self.nanos = @import("std").os.windows.QueryPerformanceCounter();
                }
            };
        };
    };
};