const builtin = @import("builtin");
const system = @import("./system.zig");

pub const Clock = switch (builtin.os.tag) {
    .macos, .ios, .watchos, .tvos => DarwinClock,
    .windows => WindowsClock,
    .linux => LinuxClock,
    else => PosixClock,
};

const PosixClock = struct {

};

const DarwinClock = struct {

};

const WindowsClock = struct {
    pub fn nanoTime() u64 {
        while (true) {
            const now = @intToPtr(*volatile u64, 0x7FFE0000 + 0x8).*;
            const high = @intToPtr(*volatile u32, 0x7FFE0000 + 0x8 + 8).*;
            
            const now_high = @truncate(u32, now >> 32);
            if (now_high != high)
                continue;

            return now * 100;
        }
    }

    pub fn systemTime() u64 {
        @compileError("TODO");
    }
};

const LinuxClock = struct {

};