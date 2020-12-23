const builtin = @import("builtin");
const system = @import("./system.zig");
const atomic = @import("../../sync/atomic.zig");

pub usingnamespace switch (builtin.os.tag) {
    .linux => LinuxClock,
    .windows => WindowsClock,
    .macos, .ios, .watchos, .tvos => DarwinClock,
    .netbsd, .openbsd, .dragonfly, .freebsd, .kfreebsd => PosixClock,
    else => @compileError("OS not supported for monotonic timing"),
};

const WindowsClock = struct {
    pub fn nanotime() u64 {
        // https://www.geoffchappell.com/studies/windows/km/ntoskrnl/structs/kuser_shared_data/index.htm
        const PINTERRUPT_TIME = @intToPtr(
            *volatile extern struct {
                UserBits: u64,
                KernelUpperBits: u32,
            },
            0x7FFE0000 + 0x8,
        );

        while (true) {
            // loads guaranteed to be in order due to volatile accesses
            const kernel_now = PINTERRUPT_TIME.UserBits;
            const kernel_high = PINTERRUPT_TIME.KernelUpperBits;

            // non-matching high bits means the kernel wrote a new value
            const now_high = @intCast(u32, kernel_now >> 32);
            if (now_high != kernel_high) {
                atomic.spinLoopHint();
                continue;
            }

            // kernel value stored as units of 100ns
            return kernel_now *% 100;
        }
    }
};

const DarwinClock = struct {
    pub fn nanotime() u64 {
        // This does global caching for us internally
        var info: system.mach_timebase_info_data_t = undefined;
        if (system.mach_timebase_info(&info) != 0)
            unreachable;
        
        // Only do the scaling if there is some to be done (as mul/div can be expensive)
        var now = system.mach_absolute_time();
        if (info.numer != 1)
            now *= info.numer;
        if (info.denom != 1)
            now /= info.denom;

        return now;
    }
};

const PosixClock = struct {
    pub fn nanotime() u64 {

    }
};

const LinuxClock = struct {
    pub fn nanotime() u64 {
        // VDSO thoughts: 
        // https://paste.rs/bSN.C
        // https://kernel.googlesource.com/pub/scm/linux/kernel/git/luto/misc-tests/+/5655bd41ffedc002af69e3a8d1b0a168c22f2549/dump-vdso.c
    }
};