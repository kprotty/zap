const zap = @import("../zap.zig");
const builtin = zap.builtin;

pub const is_linux = builtin.os.tag == .linux;
pub const is_windows = builtin.os.tag == .windows;
pub const is_darwin = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos => true,
    else => false,
};

pub const is_netbsd = builtin.os.tag == .netbsd;
pub const is_openbsd = builtin.os.tag == .openbsd;
pub const is_dragonfly = builtin.os.tag == .dragonfly;
pub const is_freebsd = builtin.os.tag == .freebsd or .tag == .kfreebsd;
pub const is_bsd = is_netbsd or is_openbsd or is_dragonfly or is_freebsd;

pub const has_libc = builtin.link_libc;
pub const is_posix = is_linux or is_bsd or switch (builtin.os.tag) {
    .minix => true,
    else => false,
};

pub usingnamespace if (is_windows)
    @import("./windows.zig")
else if (is_linux)
    @import("./linux.zig")
else if (is_darwin)
    @import("./darwin.zig")
else
    struct {};
