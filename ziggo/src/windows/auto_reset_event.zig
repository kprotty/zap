const std = @import("std");
const system = @import("../system.zig");
const windows = @import("./windows.zig");
const nanotime = @import("./time.zig").nanotime;

pub const AutoResetEvent = extern struct {
    const State = extern enum(u32) {
        Empty,
        Waiting,
        Notified,
    };

    state: State,

    pub fn init(self: *AutoResetEvent) void {
        self.state = .Empty;
    }

    pub fn deinit(self: *AutoResetEvent) void {
        std.debug.assert(@atomicLoad(State, &self.state, .Monotonic) != .Waiting);
        self.* = undefined;
    }

    pub fn notify(self: *AutoResetEvent) void {
        var state = @atomicLoad(State, &self.state, .Monotonic);

        if (state == .Empty) {
            state = @cmpxchgStrong(
                State,
                &self.state,
                .Empty,
                .Notified,
                .Release,
                .Monotonic,
            ) orelse return;
        }

        if (state == .Notified)
            return;

        std.debug.assert(state == .Waiting);
        @atomicStore(State, &self.state, .Empty, .Release);
        self.notifyEvent();
    }

    pub fn wait(self: *AutoResetEvent) void {
        return self.tryWaitUntil(null) catch unreachable;
    }

    pub fn tryWait(self: *AutoResetEvent, deadline: u64) !void {
        return self.tryWaitUntil(deadline);
    }

    fn tryWaitUntil(self: *AutoResetEvent, deadline: ?u64) !void {
        var state = @atomicLoad(State, &self.state, .Acquire);

        if (state == .Empty) {
            state = @cmpxchgStrong(
                State,
                &self.state,
                .Empty,
                .Waiting,
                .Acquire,
                .Acquire,
            ) orelse return self.waitEvent(deadline);
        }

        std.debug.assert(state == .Notified);
        @atomicStore(State, &self.state, .Empty, .Monotonic);
    }

    fn notifyEvent(self: *AutoResetEvent) void {
        @setCold(true);
        const handle = KeyedEvent.getHandle() orelse return;
        KeyedEvent.notify(handle, &self.state);
    }

    fn waitEvent(self: *AutoResetEvent, deadline: ?u64) !void {
        @setCold(true);

        const handle = KeyedEvent.getHandle() orelse {
            while (@atomicLoad(State, &self.state, .Acquire) == .Waiting)
                system.spinLoopHint(1024);
            return;
        };
        
        var timeout: ?u64 = null;
        if (deadline) |deadline_ns| {
            const now = nanotime();
            if (now >= deadline_ns)
                return error.TimedOut;
            timeout = now - deadline_ns;
        }

        KeyedEvent.wait(handle, &self.state, timeout) catch {
            if (@cmpxchgStrong(State, &self.state, .Waiting, .Empty, .Acquire, .Acquire) == null)
                return error.TimedOut;
            KeyedEvent.wait(handle, &self.state, null) catch unreachable;
            return;
        };
    }
};

pub const KeyedEvent = struct {
    var event_state: EventState = .Uninit;
    var event_handle: windows.HANDLE = undefined;

    const EventState = enum(u8) {
        Uninit,
        Creating,
        Ready,
        Error,
    };

    pub fn getHandle() ?windows.HANDLE {
        var ev_state = @atomicLoad(EventState, &event_state, .Acquire);
        while (true) {
            switch (ev_state) {
                .Uninit => ev_state = @cmpxchgWeak(
                    EventState,
                    &event_state,
                    .Uninit,
                    .Creating,
                    .Acquire,
                    .Acquire,
                ) orelse blk: {
                    ev_state = switch (windows.ntdll.NtCreateKeyedEvent(
                        &event_handle,
                        windows.GENERIC_READ | windows.GENERIC_WRITE,
                        null,
                        0,
                    )) {
                        .SUCCESS => EventState.Ready,
                        else => EventState.Error,
                    };
                    @atomicStore(EventState, &event_state, ev_state, .Release);
                    break :blk ev_state;
                },
                .Creating => {
                    windows.kernel32.Sleep(0);
                    ev_state = @atomicLoad(EventState, &event_state, .Acquire);
                },
                .Ready => return event_handle,
                .Error => return null,
            }
        }
    }

    pub fn notify(
        handle: windows.HANDLE,
        key_ptr: var,
    ) void {
        comptime std.debug.assert(@alignOf(@TypeOf(key_ptr)) >= @alignOf(u32));
        const key = @ptrCast(*const c_void, key_ptr);
        const status = windows.ntdll.NtReleaseKeyedEvent(handle, key, windows.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    pub fn wait(
        handle: windows.HANDLE,
        key_ptr: var,
        timeout: ?u64,
    ) !void {
        comptime std.debug.assert(@alignOf(@TypeOf(key_ptr)) >= @alignOf(u32));
        const key = @ptrCast(*const c_void, key_ptr);

        var timeout_ptr: ?*windows.LARGE_INTEGER = null;
        var timeout_value: windows.LARGE_INTEGER = undefined;
        if (timeout) |timeout_ns| {
            timeout_value = @intCast(windows.LARGE_INTEGER, @divFloor(timeout_ns, 100));
            timeout_value = -timeout_value;
            timeout_ptr = &timeout_value;
        }

        switch (windows.ntdll.NtWaitForKeyedEvent(handle, key, windows.FALSE, timeout_ptr)) {
            .TIMEOUT => return error.TimedOut,
            .SUCCESS => {},
            else => unreachable,
        }
    }
};