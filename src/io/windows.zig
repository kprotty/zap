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
const windows = std.os.windows;
const zap = @import("../zap.zig");

pub const Driver = struct {
    iocp: windows.HANDLE,
    timer_res: ?windows.ULONG,

    pub fn init(self: *Driver) !void {
        self.timer_res = null;
        self.iocp = try windows.CreateIoCompletionPort(
            windows.INVALID_HANDLE_VALUE,
            null,
            undefined,
            std.math.maxInt(windows.DWORD),
        );
    }

    pub fn deinit(self: *Driver) void {
        windows.CloseHandle(self.iocp);
    }

    pub fn pause(self: *Driver) void {
        if (self.timer_res) |old_res| {
            var high_precision_res: windows.ULONG = undefined;
            const status = NtSetTimerResolution(old_res, windows.TRUE, &high_precision_res);
            std.debug.assert(status == .SUCCESS);
            std.debug.assert(high_precision_res == 1);
            self.timer_res = null;
        }
    }

    pub fn poll(self: *Driver, batch: *zap.Task.Batch, timeout_ns: ?u64) bool {
        var ts: windows.LARGE_INTEGER = undefined;
        var ts_ptr: ?*windows.LARGE_INTEGER = &ts;
        if (timoeut_ns) |timeout| {
            ts = @divFloor(timeout, 100);
            ts = -ts;
        } else {
            ts_ptr = null;
        }

        if ((timeout_ns != null) and (self.timer_res == null)) {
            self.timer_res = 0;
            if (self.timer_res) |*res| {
                const status = NtSetTimerResolution(1, windows.TRUE, res);
                std.debug.assert(status == .SUCCESS);
            }
        }

        // TODO

        return true;
    }
};

const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: windows.ULONG_PTR,
    lpOverlapped: *windows.OVERLAPPED,
    internal: windows.ULONG_PTR,
    dwNumberOfBytesTransferred: windows.DWORD,
};

const OBJECT_WAIT_TYPE = extern enum {
    WaitAllObject,
    WaitAnyObject,
};

extern "kernel32" fn GetQueuedCompletionStatusEx(
    completionPort: windows.HANDLE,
    lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
    ulCount: windows.ULONG,
    ulNumEntriesRemoved: *windows.ULONG,
    dwMilliseconds: windows.DWORD,
    fAlertable: windows.BOOL,
) callconv(.Stdcall) windows.BOOL;

extern "NtDll" fn NtSetTimerResolution(
    desiredResolution: windows.ULONG,
    setResolution: windows.BOOLEAN,
    currentResolution: *windows.ULONG,
) callconv(.Stdcall) windows.NTSTATUS;

extern "NtDll" fn NtWaitForMultipleObjects(
    objectCount: windows.ULONG,
    objectArray: [*]const windows.HANDLE,
    waitType: OBJECT_WAIT_TYPE,
    alertable: windows.BOOLEAN,
    timeout: ?*windows.LARGE_INTEGER,
) callconv(.Stdcall) @TagType(windows.NTSTATUS);
