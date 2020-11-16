const std = @import("std");
const system = std.os.system;

pub const Event = struct {
    key: u32 = undefined,

    pub fn reset(self: *Event) void {}

    pub fn wait(self: *Event) void {
        const key = @ptrCast(*align(4) const c_void, &self.key);
        const status = NtWaitForKeyedEvent(null, key, system.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    pub fn notify(self: *Event) void {
        const key = @ptrCast(*align(4) const c_void, &self.key);
        const status = NtReleaseKeyedEvent(null, key, system.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }
};

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
