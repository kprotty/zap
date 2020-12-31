const zap = @import(".../zap.zig");
const system = zap.system;
const atomic = zap.sync.atomic;

pub fn nanoTime() u64 {
    return readUserDataTimeAt(0x08);
}

pub fn systemTime() u64 {
    return readUserDataTimeAt(0x14);
}

fn readUserDataTimeAt(comptime offset: comptime_int) u64 {
    // https://www.geoffchappell.com/studies/windows/km/ntoskrnl/structs/kuser_shared_data/index.htm
    const KUSER_DATA_PTR = 0x7FFE0000;
    const KTIME_PTR = @intToPtr(
        *volatile system.KSYSTEM_TIME,
        KUSER_DATA_PTR + offset,
    );

    while (true) {
        const user_low = atomic.load(&KTIME_PTR.LowPart, .unordered);
        const user_high = atomic.load(&KTIME_PTR.High1Time, .unordered);
        const kernel_high = atomic.load(&KTIME_PTR.High2Time, .unordered);

        if (user_high != kernel_high)
            continue;

        var time: u64 = 0;
        time |= @as(u64, @bitCast(system.ULONG, user_low));
        time |= @as(u64, @bitCast(system.ULONG, user_high)) << 32;
        return time;
    }
}