const builtin = @import("builtin");

pub const os = builtin.os.tag;
pub const arch = builtin.arch;
pub const has_libc = builtin.link_libc;
pub const is_parallel = !builtin.single_threaded;

pub const is_linux = os == .linux;
pub const is_windows = os == .windows;
pub const is_darwin = switch (os) {
    .macos, .ios, .tvos, .watchos => true,
    else => false,
};

pub const is_bsd = is_darwin or switch (os) {
    .openbsd, .freebsd, .kfreebsd, .netbsd, .dragonfly => true,
    else => false,
};

pub const is_posix = is_linux or is_bsd or switch (os) {
    .minix, .haiku => true,
    else => false,
};

pub const is_x86 = arch == .i386 or arch == .x86_64;
pub const is_arm = arch == .arm or arch == .aarch64;
pub const is_riscv = arch == .riscv or arch == .riscv64;
pub const is_ppc = switch (arch) {
    .powerpc, .powerpc64 => true,
    else => false,
};
