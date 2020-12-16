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
    thread_id: u32 = 0,

    pub fn wait(self: *Event, deadline: ?u64, condition: anytype) error{TimedOut}!void {
        if (self.thread_id == 0)
            self.thread_id = GetCurrentThreadIdFast();
        
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

        const deadline_ns = switch (NtWaitForAlertByThreadId(0, timeout_ptr)) {
            STATUS_ALERTED => return,
            STATUS_TIMEOUT => deadline_ns orelse unreachable,
            else => unreachable,
        };
        
        const now = nanotime();
        if (now > deadline_ns)
            return error.TimedOut;
    }

    pub fn notify(self: *Event) void {
        const status = NtAlertThreadByThreadId(self.thread_id);
        if (status != 0)
            unreachable;
    }

    inline fn GetCurrentThreadIdFast() u32 {
        // https://en.wikipedia.org/wiki/Win32_Thread_Information_Block
        return switch (builtin.arch) {
            .i386 => asm volatile (
                \\ movl %%fs:0x24, %[tid]
                : [tid] "=r" (-> u32)
            ),
            .x86_64 => asm volatile (
                \\ movl %%gs:0x48, %[tid]
                : [tid] "=r" (-> u32)
            ),
            else => GetCurrentThreadId(),
        };
    }

    const STATUS_ALERTED = 0x101;
    const STATUS_TIMEOUT = 0x102;
    const WINAPI = if (builtin.arch == .i386) .Stdcall else .C;

    extern "kernel32" fn GetCurrentThreadId() callconv(WINAPI) u32;
    extern "NtDll" fn NtAlertThreadByThreadId(
        thread_id: usize,
    ) callconv(WINAPI) u32;
    extern "NtDll" fn NtWaitForAlertByThreadId(
        address: usize,
        timeout: ?*const i64,
    ) callconv(WINAPI) u32;
};

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



