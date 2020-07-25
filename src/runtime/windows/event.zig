// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const windows = @import("./windows.zig");

pub const Event = struct {
    state: State,

    const State = enum(u32) {
        empty,
        waiting,
        notified,
    };

    pub fn init(noalias self: *Event) void {
        self.state = .empty;
    }

    pub fn deinit(noalias self: *Event) void {
        switch (@atomicLoad(State, &self.state, .Monotonic)) {
            .empty => self.* = undefined,
            .waiting => std.debug.panic("Event.deinit() with pending waiter", .{}),
            .notified => std.debug.panic("Event.deinit() with missing notification", .{}),
        }
    }

    pub fn notify(noalias self: *Event) void {
        if (@cmpxchgStrong(
            State,
            &self.state,
            .empty,
            .notified,
            .Release,
            .Monotonic,
        )) |state| {
            switch (state) {
                .empty => unreachable,
                .waiting => KeyedEvent.notify(@ptrCast(KeyedEvent.Key, &self.state)),
                .notified => std.debug.panic("Event.notify() when already notified", .{}),
            }
        }
    }

    pub fn wait(noalias self: *Event) void {
        if (@cmpxchgStrong(
            State,
            &self.state,
            .empty,
            .waiting,
            .Acquire,
            .Acquire,
        )) |state| {
            switch (state) {
                .empty => unreachable,
                .waiting => std.debug.panic("Event.wait() when already waiting", .{}),
                .notified => @atomicStore(State, &self.state, .empty, .Monotonic),
            }
        } else {
            KeyedEvent.wait(@ptrCast(KeyedEvent.Key, &self.state), null) catch unreachable;
            @atomicStore(State, &self.state, .empty, .Monotonic);
        }
    }
};

pub const KeyedEvent = struct {
    pub const Key = *align(4) const c_void;
    const EVENT_HANDLE = @as(?windows.HANDLE, null);

    pub fn notify(key: Key) void {
        const status = NtReleaseKeyedEvent(EVENT_HANDLE, key, windows.FALSE, null);
        return switch (status) {
            .SUCCESS => {},
            else => {
                @setEvalBranchQuota(4000);
                std.debug.panic("KeyedEvent.notify() with unknown status {}", .{status});
            },
        };
    }

    pub fn wait(key: Key, timeout_ns: ?u64) error{TimedOut}!void {
        var timeout_value: windows.LARGE_INTEGER = undefined;
        var timeout_ptr: ?*windows.LARGE_INTEGER = null;
        if (timeout_ns) |timeout| {
            timeout_ptr = &timeout_value;
            timeout_value = @intCast(windows.LARGE_INTEGER, timeout);
            timeout_value = @divFloor(timeout_value, 100);
            timeout_value = -timeout_value;
        }

        const status = NtWaitForKeyedEvent(EVENT_HANDLE, key, windows.FALSE, timeout_ptr);
        return switch (status) {
            .SUCCESS => {},
            .TIMEOUT => error.TimedOut,
            else => {
                @setEvalBranchQuota(4000);
                std.debug.panic("KeyedEvent.wait() with unknown status {}", .{status});
            },
        };
    }
    
    extern "NtDll" fn NtWaitForKeyedEvent(
        EventHandle: ?windows.HANDLE,
        Key: Key,
        Alertable: windows.BOOLEAN,
        Timeout: ?*windows.LARGE_INTEGER,
    ) callconv(.Stdcall) windows.NTSTATUS;

    
    extern "NtDll" fn NtReleaseKeyedEvent(
        EventHandle: ?windows.HANDLE,
        Key: Key,
        Alertable: windows.BOOLEAN,
        Timeout: ?*windows.LARGE_INTEGER,
    ) callconv(.Stdcall) windows.NTSTATUS;
};