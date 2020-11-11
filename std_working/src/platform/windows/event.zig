const std = @import("std");
const zap = @import("../../zap.zig");

const system = std.os.system;
const sync = zap.core.sync;
const Condition = sync.Condition;
const Atomic = sync.atomic.Atomic;

pub const Event = extern struct {
    state: Atomic(State) = undefined,

    const State = extern enum(system.DWORD) {
        waiting,
        notified,
    };

    pub fn wait(self: *Event, deadline: ?u64, condition: *Condition, comptime nanotimeFn: anytype) bool {
        self.state.set(.waiting);

        if (condition.isMet())
            return true;

        var timed_out = false;
        var timeout: system.LARGE_INTEGER = undefined;
        var timeout_ptr: ?*system.LARGE_INTEGER = null;

        if (deadline) |deadline_ns| {
            const now = nanotimeFn();
            timed_out = now > deadline_ns;
            if (!timed_out) {
                timeout_ptr = &timeout;
                timeout = @intCast(system.LARGE_INTEGER, deadline_ns - now);
                timeout = -(@divFloor(timeout, 100));
            }
        }

        const key = @ptrCast(?*align(4) const c_void, &self.state);
        if (!timed_out) {
            switch (NtWaitForKeyedEvent(null, key, system.FALSE, timeout_ptr)) {
                .TIMEOUT => {},
                .SUCCESS => return true,
                else => @panic("NtWaitForKeyedEvent() unhandled status code"),
            }
        }

        if (self.state.swap(.notified, .acquire) == .notified) {
            switch (NtWaitForKeyedEvent(null, key, system.FALSE, null)) {
                .SUCCESS => {},
                else => @panic("NtWaitForKeyedEvent() unhandled status code"),
            }
        }

        return false;
    }

    pub fn notify(self: *Event) void {
        const state = self.state.swap(.notified, .release);
        if (state == .notified)
            return;

        const key = @ptrCast(?*align(4) const c_void, &self.state);
        switch (NtReleaseKeyedEvent(null, key, system.FALSE, null)) {
            .SUCCESS => {},
            else => @panic("NtReleaseKeyedEvent() unhandled status code"),
        }
    }

    pub const is_actually_monotonic = false;

    pub fn nanotime(comptime getCachedFn: anytype) u64 {
        const frequency = getCachedFn(struct {
            fn get() u64 {
                var frequency: system.LARGE_INTEGER = undefined;
                if (system.kernel32.QueryPerformanceFrequency(&frequency) != system.TRUE)
                    @panic("QueryPerformanceFrequency failed");
                return @intCast(u64, frequency);
            }
        }.get);

        const counter = blk: {
            var counter: system.LARGE_INTEGER = undefined;
            if (system.kernel32.QueryPerformanceCounter(&counter) != system.TRUE)
                @panic("QueryPerformanceCounter failed");
            break :blk @intCast(u64, counter);
        };

        return @divFloor(counter *% std.time.ns_per_s, frequency);
    }

    extern "NtDll" fn NtWaitForKeyedEvent(
        handle: ?system.HANDLE,
        key: ?*align(4) const c_void,
        alertable: system.BOOLEAN,
        timeout: ?*const system.LARGE_INTEGER,
    ) callconv(.Stdcall) system.NTSTATUS;

    extern "NtDll" fn NtReleaseKeyedEvent(
        handle: ?system.HANDLE,
        key: ?*align(4) const c_void,
        alertable: system.BOOLEAN,
        timeout: ?*const system.LARGE_INTEGER,
    ) callconv(.Stdcall) system.NTSTATUS;
};