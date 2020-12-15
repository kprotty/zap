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

// futex
const LinuxEvent = @compileError("TODO");

// lwp_park
const NetBSDEvent = @compileError("TODO");

// thrsleep/thrwakeup
const OpenBSDEvent = @compileError("TODO");

// umtx_op
const FreeBSDEvent = @compileError("TODO");

// sys_umtx_op
const DragonflyEvent = @compileError("TODO");

// pthread with static init but no destroy as not needed
const DarwinEvent = @compileError("TODO");

// NtWaitForAlertByThreadId / NtAlertThreadByThreadId 
// (functions used in WaitOnAddress / SRWLOCK / CONDITION_VARIABLE)
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

