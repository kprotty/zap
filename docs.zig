const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;
extern "kernel32" stdcallcc fn CreateProcessA(
    lpApplicationName: ?[*]const u8,
    lpCommandLine: ?[*]const u8,
    lpProcessAttributes: usize,
    lpThreadAttributes: usize,
    bInheritHandles: windows.BOOL,
    dwCreationFlags: windows.DWORD,
    lpEnvironment: usize,
    lpCurrentDirectory: usize,
    lpStartupInfo: usize,
    lpProcessInformation: usize,
) windows.BOOL;

pub fn main() void {
    if (builtin.os == .windows) {
        var startup_info: [104]u8 align(8) = undefined;
        std.mem.set(u8, startup_info[0..], 0);
        const s_ptr = @ptrToInt(startup_info[0..].ptr);
        var proc_info: [@sizeOf(windows.HANDLE) * 2 + @sizeOf(windows.DWORD) * 2]u8 align(8) = undefined;
        std.mem.set(u8, proc_info[0..], 0);
        const p_ptr = @ptrToInt(proc_info[0..].ptr);
        const cmd = c"ROBOCOPY.exe zig-cache/docs docs /move /NFL /NDL /NJH /NJS /nc /ns /np";
        std.debug.assert(CreateProcessA(null, cmd, 0, 0, windows.FALSE, 0, 0, 0, s_ptr, p_ptr) == windows.TRUE);
    } else {
        @compileError("Move docs to root folder for unix");
    }
}
