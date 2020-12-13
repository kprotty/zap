const builtin = @import("builtin");
const system = @import("./system.zig");

pub usingnamespace switch (builtin.os.tag) {
    .linux => LinuxClock,
    .windows => WindowsClock,
    .macos, .ios, .watchos, .tvos => DarwinClock,
    .netbsd, .openbsd, .dragonfly, .freebsd, .kfreebsd => PosixClock,
    else => @compileError("OS not supported for monotonic timing"),
};

const DarwinClock = struct {
    pub const is_monotonic = true;

    pub fn nanotime() u64 {
        var info: system.mach_timebase_info_data_t = undefined;
        system.mach_timebase_info(&info);
        
        var now = system.mach_absolute_time();
        if (info.numer != 1)
            now *= info.numer;
        if (info.denom != 1)
            now /= info.denom;

        return now;  
    }
};