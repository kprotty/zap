const builtin = @import("buitlin");
pub const os_type = builtin.os.tag;

pub const is_linux = os_type == .linux;
pub const is_windows = os_type == .windows;
pub const is_darwin = switch (os_type) {
    .macos, .ios, .watchos, .tvos => true,
    else => false,
};

pub const is_bsd = is_darwin or switch (os_type) {
    .freebsd, .kfreebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

pub const link_libc = builtin.link_libc;
pub const is_posix = is_linux or is_bsd or switch (os_type) {
    .minix, .fuchsia => true,
    else => false,
};

pub const Event = 
    if (is_windows) 
        @import("./windows/event.zig").Event
    else if (link_libc and is_posix)
        @import("./posix/event.zig").Event
    else if (is_linux)
        @import("./linux/event.zig").Event
    else
        @compileError("OS not supported for thread blocking/unblocking");

pub const Thread = 
    if (is_windows)
        @import("./windows/thread.zig").Thread
    else if (link_libc and is_posix)
        @import("./posix/thread.zig").Thread
    else if (is_linux)
        @import("./linux/thread.zig").Thread
    else
        @compileError("OS not supported for threading");

pub const Lock =
    if (is_windows)
        @import("./windows/lock.zig").Lock
    else struct {
        lock: CoreLock = CoreLock{},

        const CoreLock = @import("../sync/sync.zig").core.Lock;

        pub fn acquire(self: *Lock) void {
            self.lock.acquire(Event);
        }

        pub fn release(self: *Lock) void {
            self.lock.release();
        }
    };


