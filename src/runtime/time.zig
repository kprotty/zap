const zap = @import("../zap.zig");
const target = zap.runtime.target;
const system = zap.runtime.system;
const atomic = zap.sync.atomic;

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
        const frequency = 
            if (@sizeOf(usize) < 8) getFrequencyTLS()
            else getFrequencyGlobal();
        const counter = getCounter();
        const nanos_per_sec = 1_000_000_000;
        return @divFloor(counter *% nanos_per_sec, frequency);
    }

    fn getFrequencyTLS() u64 {
        const TLS = struct {
            threadlocal var frequency: ?u64 = null;
        };

        return TLS.frequency orelse blk: {
            var frequency = getFrequency();
            TLS.frequency = frequency;
            break :blk frequency;
        };
    }

    fn getFrequencyGlobal() u64 {
        const Global = struct {
            var frequency: u64 = 0;
        };

        var frequency = atomic.load(&Global.frequency, .relaxed);
        if (frequency != 0)
            return frequency;

        frequency = getFrequency();
        atomic.store(&Global.frequency, frequency, .relaxed);
        return frequency;
    }

    fn getFrequency() u64 {
        var frequency: system.LARGE_INTEGER = undefined;
        if (system.QueryPerformanceFrequency(&frequency) != system.TRUE)
            unreachable;
        return @intCast(u64, frequency);
    }

    fn getCounter() u64 {
        var counter: system.LARGE_INTEGER = undefined;
        if (system.QueryPerformanceCounter(&counter) != system.TRUE)
            unreachable;
        return @intCast(u64, counter);
    }
};

const DarwinClock = struct {
    fn nanotime() u64 {

    }
};
