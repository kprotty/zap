const zap = @import("../zap.zig");
const target = zap.runtime.target;
const system = zap.runtime.system;
const atomic = zap.sync.atomic;
const ns_per_s = zap.time.ns_per_s;

pub const Clock = 
    if (target.is_windows)
        WindowsClock
    else if (target.is_darwin)
        DarwinClock
    else if (target.is_posix)
        PosixClock
    else
        @compileError("OS not supported for monotonic clocks");

const PosixClock = struct {
    pub const is_monotonic = switch (target.os) {
        .linux => switch (target.arch) {
            .s390x, .aarch64 => false,
            else => target.abi != .android,
        },
        .openbsd => target.arch != .x86_64,
        else => true,
    };

    pub fn nanotime() u64 {

    }
};

const WindowsClock = struct {
    pub const is_monotonic = false;

    pub fn nanotime() u64 {
        const frequency = 
            if (@sizeOf(usize) < 8) getFrequencyTLS()
            else getFrequencyGlobal();
        const counter = getCounter();
        return @divFloor(counter *% ns_per_s, frequency);
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
    pub const is_monotonic = true;

    pub fn nanotime() u64 {

    }
};
