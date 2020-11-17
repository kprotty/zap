const system = @import("./system.zig");
const atomic = @import("../../sync/sync.zig").core.atomic;

pub const Event = struct {
    key: u32 = undefined,

    pub fn wait(self: *Event, deadline: ?Timestamp) void {
        const key = @ptrCast(*align(4) const c_void, &self.key);
        switch (system.NtWaitForKeyedEvent(null, key, system.FALSE, null)) {
            system.STATUS_SUCCESS => {},
            else => unreachable,
        }
    }

    pub fn notify(self: *Event) void {
        const key = @ptrCast(*align(4) const c_void, &self.key);
        switch (system.NtReleaseKeyedEvent(null, key, system.FALSE, null)) {
            system.STATUS_SUCCESS => {},
            else => unreachable,
        }
    }

    pub fn yield(iteration: ?usize) bool {
        const iter = iteration orelse {
            _ = system.SleepEx(1, system.FALSE);
            return false;
        };

        if (iter < 4000) {
            atomic.spinLoopHint();
            return true;
        }

        return false;
    }

    pub fn nanotime() u64 {
        const frequency = getFrequency();
        const ns_per_sec = 1_000_000_000;

        const counter = blk: {
            var perf_counter: system.LARGE_INTEGER = undefined;
            if (system.QueryPerformanceCounter(&perf_counter) != system.TRUE)
                unreachable;
            break :blk @intCast(u64, perf_counter);  
        };

        return @divFloor(counter *% ns_per_sec, frequency);
    }

    inline fn getFrequency() u64 {
        return (struct {
            threadlocal var tls_frequency: u64 = 0;

            inline fn get() u64 {
                const frequency = tls_frequency;
                if (frequency == 0)
                    return @call(.{ .modifier = .inline_never }, getSlow, .{});
                return frequency;
            }

            fn getSlow() u64 {
                @setCold(true);

                const frequency = blk: {
                    var perf_frequency: system.LARGE_INTEGER = undefined;
                    if (system.QueryPerformanceFrequency(&perf_frequency) != system.TRUE)
                        unreachable;
                    break :blk @intCast(u64, perf_frequency);
                };

                tls_frequency = frequency;
                return frequency;
            }
        }).get();
    }
};
