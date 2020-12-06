const zap = @import("../zap.zig");
const target = zap.runtime.target;

pub const nanotime = 
    if (target.is_windows)
        WindowsClock.nanotime
    else if (target.is_darwin)
        DarwinClock.nanotime
    else if (target.is_posix)
        PosixClock.nanotime
    else
        @compileError("OS not supported for monotonic timers");

const PosixClock = struct {
    fn nanotime() u64 {

    }
};

const WindowsClock = struct {
    fn nanotime() u64 {

    }
};

const DarwinClock = struct {
    fn nanotime() u64 {

    }
};
