const std = @import("std");
const windows = std.os.windows;

const zap = @import("../../zap.zig");
const OsFutex = zap.runtime.sync.OsFutex;
const Atomic = zap.core.sync.atomic.Atomic;

pub const Event = extern struct {
    updated: Atomic(u32) = undefined,

    pub fn prepare(self: *Event) void {
        self.updated.set(0);
    }

    pub fn wait(self: *Event, deadline: ?u64) bool {
        if (self.updated.fetchAdd(1, .acquire) != 0)
            return true;
        return self.waitSlow(deadline);
    }

    fn waitSlow(self: *Event, deadline: ?u64) bool {
        const handle: ?windows.HANDLE = null;
        const key = @ptrCast(*align(4) const c_void, &self.updated);

        var timed_out = false;
        var timeout: windows.LARGE_INTEGER = undefined;
        var timeout_ptr: ?*windows.LARGE_INTEGER = null;

        if (deadline) |deadline_ns| {
            const now = OsFutex.nanotime();
            timed_out = now > deadline_ns;
            if (!timed_out) {
                timeout_ptr = &timeout;
                timeout = @intCast(windows.LARGE_INTEGER, deadline_ns - now);
                timeout = -@divFloor(timeout, 100);
            }
        }

        if (!timed_out) {
            const status = NtWaitForKeyedEvent(handle, key, windows.FALSE, timeout_ptr);
            switch (status) {
                .SUCCESS => return true,
                .TIMEOUT => {},
                else => unreachable, // unknown NtWaitForKeyedEvent status
            }
        }

        _ = self.updated.compareAndSwap(
            1,
            0,
            .acquire,
            .acquire,
        ) orelse return false;

        const status = NtWaitForKeyedEvent(handle, key, windows.FALSE, timeout_ptr);
        std.debug.assert(status == .SUCCESS);
        return true;
    }

    pub fn notify(self: *Event) void {
        if (self.updated.fetchAdd(1, .release) != 0)
            self.notifySlow();
    }

    fn notifySlow(self: *Event) void {
        @setCold(true);

        const handle: ?windows.HANDLE = null;
        const key = @ptrCast(*align(4) const c_void, &self.updated);

        const status = NtReleaseKeyedEvent(handle, key, windows.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    pub fn yield() void {
        _ = SleepEx(1, windows.FALSE);
    }

    pub const is_monotonic = false;

    pub fn nanotime() u64 {
        const Frequency = struct {
            var frequency_state = Atomic(State).init(.uninit);
            var frequency: windows.LARGE_INTEGER = undefined;

            const State = enum(usize) {
                uninit,
                storing,
                init,
            };

            fn get() @TypeOf(frequency) {
                if (frequency_state.load(.acquire) == .init)
                    return frequency;
                return getSlow();
            }

            fn getSlow() @TypeOf(frequency) {
                @setCold(true);

                var freq: windows.LARGE_INTEGER = undefined;
                std.debug.assert(QueryPerformanceFrequency(&freq) == windows.TRUE); 

                _ = frequency_state.compareAndSwap(
                    .uninit,
                    .init,
                    .relaxed,
                    .relaxed,
                ) orelse {
                    frequency = freq;
                    frequency_state.store(.init, .release);
                    return freq;
                };

                return freq;
            }
        };

        const frequency = Frequency.get();
        
        var counter: windows.LARGE_INTEGER = undefined;
        std.debug.assert(QueryPerformanceCounter(&counter) == windows.TRUE);

        const nanos = @divFloor(counter *% std.time.ns_per_s, frequency);
        return @intCast(u64, nanos);
    }
};

extern "kernel32" fn SleepEx(
    ms: windows.DWORD,
    alertable: windows.BOOL,
) callconv(.Stdcall) windows.DWORD;

extern "kernel32" fn QueryPerformanceFrequency(
    frequency: *windows.LARGE_INTEGER,
) callconv(.Stdcall) windows.BOOL;

extern "kernel32" fn QueryPerformanceCounter(
    frequency: *windows.LARGE_INTEGER,
) callconv(.Stdcall) windows.BOOL;

extern "NtDll" fn NtWaitForKeyedEvent(
    handle: ?windows.HANDLE,
    key: ?*align(4) const c_void,
    alertable: windows.BOOLEAN,
    timeout: ?*const windows.LARGE_INTEGER,
) callconv(.Stdcall) windows.NTSTATUS;

extern "NtDll" fn NtReleaseKeyedEvent(
    handle: ?windows.HANDLE,
    key: ?*align(4) const c_void,
    alertable: windows.BOOLEAN,
    timeout: ?*const windows.LARGE_INTEGER,
) callconv(.Stdcall) windows.NTSTATUS;
