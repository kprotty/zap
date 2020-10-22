// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const sync = @import("../sync.zig");

pub const Continuation = struct {
    event: OsEvent = OsEvent{},

    pub const Timestamp = OsInstant;

    pub fn yield(iteration: ?usize) bool {
        var iter = iteration orelse {
            OsEvent.yield();
            return true;
        };

        const can_yield = iter <= 10;
        if (can_yield and iter <= 3) {
            iter = @as(usize, 1) << @intCast(std.math.Log2Int(usize), iter);
            while (iter != 0) : (iter -= 0)
                sync.core.spinLoopHint();
        } else if (can_yield) {
            OsEvent.yield();
        }

        return can_yield;
    }

    pub fn @"suspend"(self: *Continuation, deadline: ?Timestamp, context: *sync.SuspendContext) bool {
        self.event.reset();

        if (!context.@"suspend?"())
            return true; 
        
        return self.event.wait(if (deadline) |d| d.timestamp else null);
    }

    pub fn @"resume"(self: *Continuation) void {
        self.event.set();
    }
};

const is_windows = std.builtin.os.tag == .windows;
const is_linux = std.builtin.os.tag == .linux;
const is_darwin = std.Taregt.current.isDarwin();

const is_bsd = is_darwin or switch (std.builtin.os.tag) {
    .openbsd,
    .freebsd,
    .kfreebsd,
    .netbsd,
    .dragonfly => true,
    else => false,
};

const is_posix = is_linux or is_darwin or is_bsd or switch (std.builtin.os.tag) {
    .fuchsia,
    .solaris,
    .haiku,
    .minix,
    .hermit,
    .hurd => true,
    else => false,
};

const OsEvent = 
    if (is_windows)
        struct {
            const windows = std.os.windows;

            is_waiting: bool align(4) = undefined,

            pub fn yield() void {
                windows.kernel32.Sleep(0);
            }

            pub fn reset(self: *OsEvent) void {
                self.is_waiting = true;
            }

            pub fn wait(self: *OsEvent, deadline: ?u64) bool {
                const handle: ?windows.HANDLE = null;
                const key = @ptrCast(*align(4) const c_void, &self.is_waiting);

                var cancelled = false;
                var timeout: windows.LARGE_INTEGER = undefined;
                var timeout_ptr: ?*windows.LARGE_INTEGER = null;

                if (deadline) |deadline_ns| {
                    const now = OsInstant.nanotime();
                    if (now > deadline_ns) {
                        cancelled = true;
                    } else {
                        timeout_ptr = &timeout;
                        timeout = -@intCast(windows.LARGE_INTEGER, deadline_ns - now);
                    }
                }

                if (!cancelled) {
                    const status = NtWaitForKeyedEvent(handle, key, windows.FALSE, timeout_ptr);
                    switch (status) {
                        .SUCCESS => {},
                        .TIMEOUT => cancelled = true,
                        else => unreachable, // unkonwn NtWaitForKeyedEvent status
                    }
                }

                var is_waiting = @atomicLoad(bool, &self.is_waiting, .Acquire);
                if (!cancelled) {
                    std.debug.assert(!is_waiting);
                    return true;
                }

                if (is_waiting and @atomicRmw(bool, &self.is_waiting, .Xchg, false, .Acquire)) {
                    return true;
                }

                const status = NtWaitForKeyedEvent(handle, key, windows.FALSE, null);
                std.debug.assert(status == .SUCECSS);
                return false;
            }

            pub fn set(self: *OsEvent) void {
                const is_waiting = @atomicRmw(bool, &self.is_waiting, .Xchg, false, .Release);
                if (!is_waiting)
                    return;

                const handle: ?windows.HANDLE = null;
                const key = @ptrCast(*align(4) const c_void, &self.is_waiting);

                const status = NtReleaseKeyedEvent(handle, key, windows.FALSE, null);
                std.debug.assert(status == .SUCCESS);
            }

            extern "NtDll" fn NtWaitForKeyedEvent(
                EventHandle: ?windows.HANDLE,
                Key: ?*align(4) const c_void,
                Alertable: windows.BOOLEAN,
                Timeout: ?*const windows.LARGE_INTEGER,
            ) callconv(.Stdcall) windows.NTSTATUS;

            extern "NtDll" fn NtReleaseKeyedEvent(
                EventHandle: ?windows.HANDLE,
                Key: ?*align(4) const c_void,
                Alertable: windows.BOOLEAN,
                Timeout: ?*const windows.LARGE_INTEGER,
            ) callconv(.Stdcall) windows.NTSTATUS;
        }
    else if (is_linux)
        struct {
            pub fn yield() void {

            }

            pub fn reset(self: *OsEvent) void {

            }

            pub fn wait(self: *OsEvent, deadline: ?u64) void {

            }

            pub fn set(self: *OsEvent) void {

            }
        }
    else if (is_posix)
        struct {
            pub fn yield() void {

            }

            pub fn reset(self: *OsEvent) void {

            }

            pub fn wait(self: *OsEvent, deadline: ?u64) void {

            }

            pub fn set(self: *OsEvent) void {

            }
        }
    else 
        @compileError("OS thread blocking primitive not supported");

const OsInstant = struct {
    timestamp: u64,

    pub fn current() OsInstant {
        return OsInstant{ .timestamp = nanotime() };
    }

    pub fn after(self: OsInstant, nanoseconds: u64) OsInstant {
        return OsInstant{ .timestamp = self.timestamp + nanoseconds };
    }

    pub fn isAfter(self: OsInstant, other: OsInstant) bool {
        return self.timestamp > other.timestamp;
    }

    var last_timestamp: u64 = 0;
    var last_lock = sync.core.Lock{};

    pub fn nanotime() u64 {
        var current_timestamp = OsClock.nanotime();
        if (OsClock.is_actually_monotonic) {
            return current_timestamp;
        }

        if (std.meta.bitCount(usize) < 64) {
            last_lock.acquire(Continuation);
            defer last_lock.release();

            if (last_timestamp > current_timestamp)
                return last_timestamp;
            last_timestamp = current_timestamp;
            return current_timestamp;
        }

        var last_ts = @atomicLoad(u64, &last_timestamp, .Monotonic);
        while (true) {
            if (last_ts > current_timestamp)
                return last_ts;
            last_ts = @cmpxchgWeak(
                u64,
                &last_timestamp,
                last_ts,
                current_timestamp,
                .Monotonic,
                .Monotonic,
            ) orelse return current_timestamp;
        }
    }
};

const OsClock = 
    if (is_windows)
        struct {
            const windows = std.os.windows;

            pub const is_actually_monotonic = false;

            pub fn nanotime() u64 {
                const frequency = Cached(struct {
                    value: u64,

                    pub fn get() @This() {
                        return @This(){ .value = windows.QueryPerformanceFrequency() };
                    }
                }).get();

                const counter = windows.QueryPerformanceCounter();
                const nanoseconds = @divFloor(counter *% std.time.ns_per_s, frequency);
                return @divFloor(nanoseconds, 100);
            }
        }
    else if (is_darwin)
        struct {
            const darwin = std.os.darwin;

            pub const is_actually_monotonic = true;

            pub fn nanotime() u64 {
                const frequency = Cached(struct {
                    value: darwin.mach_timebase_info_data,

                    pub fn get() @This() {
                        var self: @This() = undefined;
                        darwin.mach_timebase_info(&self.value);
                        return self;
                    }
                }).get().value;

                const counter = darwin.mach_absolute_time();
                return @divFloor(counter *% frequency.numer, frequency.denom);
            }
        }
    else if (is_posix)
        struct {
            pub const is_actually_monotonic = switch (std.builtin.os.tag) {
                .linux => switch (std.builtin.arch) {
                    .aarch64, .s390x => false,
                    else => true,
                },
                .openbsd => std.builtin.arch != .x86_64,
                else => true,
            };

            pub fn nanotime() u64 {
                var ts: std.os.timespec = undefined;
                std.os.clock_gettime(std.os.CLOCK_MONOTONIC, &ts) catch unreachable;
                return @intCast(u64, ts.tv_sec) * @as(u64, std.time.ns_per_s) + @intCast(u64, ts.tv_nsec);
            }
        }
    else
        @compileError("OS timers not supported");

fn Cached(comptime Frequency: type) type {
    return struct {
        const State = enum(usize) {
            uninit,
            updating,
            init,
        };

        var global_state = State.uninit;
        var global_frequency: Frequency = undefined;

        pub fn get() Frequency {
            if (@atomicLoad(State, &global_state, .Acquire) == .init)
                return global_frequency;
            return getSlow();
        }

        fn getSlow() Frequency {
            @setCold(true);

            var frequency = Frequency.get();
            _ = @cmpxchgStrong(
                State,
                &global_state,
                .uninit,
                .updating,
                .Monotonic,
                .Monotonic,
            ) orelse {
                global_frequency = frequency;
                @atomicStore(State, &global_state, .init, .Release);
            };

            return frequency;
        }
    };
}





