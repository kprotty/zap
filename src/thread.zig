const os = @import("os.zig");
const memory = @import("memory.zig");

pub const STACK_SIZE = 1 * 1024 * 1024;
pub const Handle = os.HANDLE;

pub fn spawn(handle: *Handle, comptime function: var, context: var) !void {
    const WinThread = struct {
        extern stdcallcc fn ThreadProc(parameter: os.PVOID) os.DWORD {
            _ = function(memory.ptrCast(@typeOf(context), parameter));
            return os.DWORD(0);
        }
    };
    return os.CreateThread(null, STACK_SIZE, WinThread.ThreadProc, memory.ptrCast(os.PVOID, context), 0, null)
        orelse return error.ThreadCreate;
}

pub fn yield() void {
    _ = SwitchToThread();
}

pub fn cpuYield() void {
    _ = asm volatile("pause" ::: "memory");
}