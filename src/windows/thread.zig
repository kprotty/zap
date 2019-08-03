const std = @import("std");
const os = @import("os.zig");
const zio = @import("../thread.zig");

pub const Id = os.DWORD;
pub const Handle = os.HANDLE;

pub fn spawn(comptime function: fn(usize) usize, parameter: usize, stack_size: usize) zio.SpawnError!Handle {
    const WinThread = struct {
        extern fn ThreadProc(param: os.LPVOID) os.DWORD {
            return @truncate(os.DWORD, function(@ptrToInt(param)));
        }
    };

    const param = @intToPtr(?os.LPVOID, parameter);
    return os.CreateThread(null, stack_size, WinThread.ThreadProc, param, 0, null) orelse {
        _ = std.os.windows.unexpectedError(os.GetLastError()) catch @panic("unexpected");
        return zio.SpawnError.Unexpected;
    };
}

pub fn wait(handle: Handle, timeout_ms: ?u32) zio.WaitError!void {
    switch (os.WaitForSingleObject(handle, timeout_ms orelse os.INFINITE)) {
        os.WAIT_TIMEOUT => return zio.WaitError.TimedOut,
        os.WAIT_OBJECT_0 => { _ = os.CloseHandle(handle); },
        else => return zio.WaitError.Unexpected,
    }
}

pub fn currentId() Id {
    return os.GetCurrentThreadId();
}

pub fn cpuCount() usize {
    var system_info: os.SYSTEM_INFO = undefined;
    os.GetSystemInfo(&system_info);
    return usize(system_info.dwNumberOfProcessors);
}