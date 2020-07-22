const std = @import("std");
const windows = std.os.windows;

pub const Event = struct {

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
                std.debug.panic("KeyedEvent.notify() with unknown status {}", status);
            },
        };
    }

    pub fn wait(key: Key, timeout_ns: ?u64) error{TimedOut}!void {
        var timeout_value: windows.LARGE_INTEGER = undefined;
        var timeout_ptr: ?*windows.LARGE_INTEGER = null;
        if (timeout_ns) |timeout| {
            timeout_ptr = &timeout_value;
            timeout_value = @intCast(windows.LARGE_INTEGER, timeout);
            timeout_value /= 100;
            timeout_value = -timeout_value;
        }

        const status = NtWaitForKeyedEvent(EVENT_HANDLE, key, windows.FALSE, timeout_ptr);
        return switch (status) {
            .SUCCESS => {},
            .TIMEOUT => error.TimedOut,
            else => {
                @setEvalBranchQuota(4000);
                std.debug.panic("KeyedEvent.wait() with unknown status {}", status);
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