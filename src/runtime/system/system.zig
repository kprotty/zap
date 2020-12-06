const zap = @import("../../zap.zig");
const target = zap.runtime.target;

pub usingnamespace
    if (target.is_windows)
        @import("./windows.zig")
    else if (target.is_linux)
        @import("./linux.zig")
    else if (target.has_libc and target.is_posix)
        @import("./posix.zig")
    else
        struct {};