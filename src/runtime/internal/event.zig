const builtin = @import("builtin");
const atomic = @import("../../sync/atomic.zig");
const nanotime = @import("./clock.zig").nanotime;

pub const Event = switch (builtin.os.tag) {
    .linux => LinuxEvent,
    .windows => WindowsEvent,
    .netbsd => NetBSDEvent,
    .openbsd => OpenBSDEvent,
    .dragonfly => DragonflyEvent,
    .freebsd, .kfreebsd => FreeBSDEvent,
    .macos, .ios, .watchos, .tvos => DarwinEvent,
    else => @compileError("OS not supported for thread blocking/unblocking"),
};

const NetBSDEvent = @compileError("TODO: lwp_park");
const FreeBSDEvent = @compileError("TODO: _umtx_op");
const OpenBSDEvent = @compileError("TODO: thrsleep/thrwakeup");
const DragonflyEvent = @compileError("TODO: sys_umtx_op");

const WindowsEvent = extern struct {
    key: u32 = undefined,

    pub fn wait(self: *Event, deadline: ?u64, condition: anytype) error{TimedOut}!void {
        if (!condition.wait())
            return;

        // Set a timeout if a valid deadline was provided.
        // Timeouts are LARGE_INTEGERs representing units of 100ns 
        // where a negative value means a relative offset.
        var timeout: i64 = undefined;
        var timeout_ptr: ?*const i64 = null;
        if (deadline) |deadline_ns| {
            const now = nanotime();
            if (now > deadline_ns)
                return error.TimedOut;
            timeout_ptr = &timeout;
            timeout = -@intCast(i64, @divFloor((now - deadline_ns), 100);
        }

        // NtWaitForKeyedEvent has no spurious wakeups.
        // We use a NULL event handle to represent the global one (\KernelObjects\CritSecOutOfMemoryEvent)
        // http://joeduffyblog.com/2006/11/28/windows-keyed-events-critical-sections-and-new-vista-synchronization-features/
        const handle = @as(?*c_void, null);
        const key = @ptrCast(?*align(4) const c_void, &self.key);
        const status = NtWaitForKeyedEvent(null, key, 0, timeout_ptr);

        const deadline_ns = switch (status) {
            STATUS_SUCCESS => return,
            STATUS_TIMEOUT => deadline_ns orelse unreachable,
            else => unreachable,
        };
        
        const now = nanotime();
        if (now > deadline_ns)
            return error.TimedOut;
    }

    pub fn notify(self: *Event) void {
        const handle = @as(?*c_void, null);
        const key = @ptrCast(?*align(4) const c_void, &self.key);
        const status = NtWaitForKeyedEvent(null, key, 0, timeout_ptr);

        if (status != STATUS_SUCCESS)
            unreachable;
    }


    const STATUS_SUCCESS = 0x000;
    const STATUS_TIMEOUT = 0x102;
    const WINAPI = if (builtin.arch == .i386) .Stdcall else .C;

    extern "NtDll" fn NtWaitForKeyedEvent(
        handle: ?*c_void,
        key: ?*align(4) const c_void,
        alertable: c_int,
        timeout: ?*const i64,
    ) callconv(WINAPI) u32;
    extern "NtDll" fn NtReleaseKeyedEvent(
        handle: ?*c_void,
        key: ?*align(4) const c_void,
        alertable: c_int,
        timeout: ?*const i64,
    ) callconv(WINAPI) u32;
};

const DarwinEvent = FutexEvent(struct {
    pub fn wait(ptr: *const i32, cmp: i32, timeout_ns: ?u64) void {
        var timeout_us = ~@as(u32, 0);
        if (timeout_ns) |timeout| {
            const wait_us = @divFloor(timeout, 1000);
            if (wait_us < @as(u64, timeout_us))
                timeout_us = @intCast(u32, wait_us);
        }
        
        const status = __ulock_wait(
            UL_COMPARE_AND_WAIT | ULF_NO_ERRNO,
            @ptrCast(?*const c_void, ptr),
            @intCast(u32, cmp),
            timeout_us,
        );

        if (status < 0) {
            switch (-status) {
                EINTR => {},
                ETIMEDOUT => {},
                else => unreachable,
            }
        }
    }

    pub fn wake(ptr: *const i32) void {
        while (true) {
            const status = __ulock_wake(
                UL_COMPARE_AND_WAIT | ULF_NO_ERRNO,
                @ptrCast(?*const c_void, ptr),
                @as(u32, 0),
                @as(u32, 0),
            );

            if (status < 0) {
                switch (-status) {
                    ENOENT => {},
                    EINTR => continue,
                    else => unreachable,
                }
            }

            return;
        }
    }

    // https://opensource.apple.com/source/xnu/xnu-6153.81.5/bsd/sys/ulock.h.auto.html

    const EINTR = 4;
    const ENOENT = 2;
    const ETIMEDOUT = 60;
    const ULF_NO_ERRNO = 0x1000000;
    const UL_COMPARE_AND_WAIT = 0x1;
    
    extern "c" fn __ulock_wait(
        operation: u32,
        address: ?*const c_void,
        value: u64,
        timeout_us: u32,
    ) callconv(.C) c_int;
    extern "c" fn __ulock_wake(
        operation: u32,
        address: ?*const c_void,
        value: u64,
    ) callconv(.C) c_int;
});

const LinuxEvent = FutexEvent(@compileError("TODO: futex()"));


fn FutexEvent(comptime Futex: type) type {
    return extern struct {
        state: State = .empty,

        const Self = @This();
        const State = enum(i32) {
            empty = 0,
            waiting = 1,
            notified = 2,
        };

        pub fn wait(self: *Self, deadline: ?u64, condition: anytype) error{TimedOut}!void {            
            if (!condition.wait())
                return;

            switch (atomic.swap(&self.state, .waiting, .acquire)) {
                .empty => {},
                .waiting => {},
                .notified => return,
            }

            while (true) {
                var timeout_ns: ?u64 = null;
                if (deadline) |deadline_ns| {
                    const now = nanotime();
                    if (now > deadline_ns) {
                        return switch (atomic.swap(&self.state, .empty, .acquire)) {
                            .empty => unreachable,
                            .waiting => error.TimedOut,
                            .notified => {},
                        };
                    } else {
                        timeout_ns = deadline_ns - now;
                    }
                }

                Futex.wait(
                    @ptrCast(*const i32, &self.state),
                    @enumToInt(State.waiting),
                    timeout_ns,
                );

                switch (atomic.load(&self.state, .acquire)) {
                    .empty => unreachable,
                    .waiting => {},
                    .notified => return,
                }
            }
        }

        pub fn notify(self: *Self) void {
            switch (atomic.swap(&self.state, .notified, .release)) {
                .empty => {},
                .waiting => Futex.wake(@ptrCast(*const i32, &self.state)),
                .notified => unreachable,
            }
        }
    };
}
