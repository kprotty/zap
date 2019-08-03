const os = @import("os.zig");
const zio = @import("../thread.zig");

pub const Handle = os.HANDLE;

pub fn spawn(comptime function: var, context: var, stack_size: usize) zio.Error!Handle {
    const Context = @typeOf(context);

    const WindowsThread = struct {
        extern fn ThreadProc(parameter: os.LPVOID) os.DWORD {
            const result = function(switch (@sizeOf(Context)) {
                0 => {},
                else => @ptrCast(*Context, @alignCast(@alignOf(Context), parameter)).*,
            });
            return switch (@typeIf(@typeOf(function).ReturnType)) {
                .Void => os.DWORD(0),
                .Int => os.DWORD(result),
                else => @compileError("Function type must return an int, void, noreturn or `!void`"),
            };
        }
    };
}

pub fn wait(handle: Handle) void {
    
}

pub fn current() Handle {
    
}

pub fn cpuCount() usize {
    
}