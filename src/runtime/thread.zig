const zap = @import("../zap.zig");
const target = zap.runtime.target;
const system = zap.runtime.system;

pub const Thread = 
    if (target.is_windows)
        WindowsThread
    else if (target.has_libc and target.is_posix)
        PosixThread
    else if (target.is_linux)
        LinuxThread
    else
        @compileError("OS not supported for threading");

const WindowsThread = struct {
    pub fn getCpuCount() usize {
        var system_info: system.SYSTEM_INFO = undefined;
        system.GetSystemInfo(&system_info);
        return system_info.dwNumberOfProcessors;
    }

    pub fn spawn(stack_size: u32, param: anytype, comptime entryFn: anytype) !void {
        const Parameter = @TypeOf(param);
        const Decorator = struct {
            fn entry(raw_arg: ?system.PVOID) callconv(.C) system.DWORD {
                const parameter = @ptrCast(Parameter, @alignCast(@alignOf(Parameter), raw_arg orelse unreachable));
                _ = @call(.{}, entryFn, .{parameter});
                return 0;
            }
        };

        const handle = system.CreateThread(
            null,
            stack_size,
            Decorator.entry,
            @ptrCast(system.PVOID, param),
            @as(system.DWORD, 0),
            null,
        ) orelse return error.SpawnError;

        if (system.CloseHandle(handle) != system.TRUE)
            unreachable;
    }
};

const PosixThread = struct {

};

const LinuxThread = struct {

};