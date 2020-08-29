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

pub const Driver = extern struct {
    iocp: windows.HANDLE,

    pub fn init(self: *Driver) !void {
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

    pub const Event = extern struct {
        inner: OVERLAPPED_ENTRY,

        pub fn getData(self: Event) usize {
            return self.inner.lpCompletionKey
        }

        pub fn isWritable(self: Event) bool {
            
        }

        pub fn isReadable(self: Event) bool {

        }
    };

    pub fn poll(self: *Driver, events: []Event, timeout: ?u64) error{TimedOut}!usize {

    }

    const OVERLAPPED_ENTRY = extern struct {
        lpCompletionKey: windows.ULONG_PTR,
        lpOverlapped: *windows.OVERLAPPED,
        internal: windows.ULONG_PTR,
        dwNumberOfBytesTransferred: windows.DWORD,
    };

    extern "kernel32" fn GetQueuedCompletionStatusEx(
        completionPort: windows.HANDLE,
        lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
        ulCount: windows.ULONG,
        ulNumEntriesRemoved: *windows.ULONG,
        dwMilliseconds: windows.DWORD,
        fAlertable: windows.BOOL,
    ) callconv(.Stdcall) windows.BOOL;
};