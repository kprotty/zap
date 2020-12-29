const zap = @import("../zap");
const builtin = zap.builtin;
const system = zap.system;

pub const ns_per_us = 1000;
pub const ns_per_ms = ns_per_us * 1000;
pub const ns_per_s = ns_per_ms * 1000;
pub const ns_per_min = ns_per_s * 60;
pub const ns_per_hour = ns_per_min * 60;

pub const OsClock = if (system.is_windows)
    @import("./clock/windows.zig")
else if (system.is_linux)
    @import("./clock/linux.zig")
else if (system.is_darwin)
    @import("./clock/darwin.zig")
else if (system.has_libc and system.is_posix)
    @import("./clock/posix.zig")
else
    @compileError("OS clock not supported");
