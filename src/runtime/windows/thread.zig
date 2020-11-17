const system = @import("./system.zig");
const Atomic = @import("../../sync/sync.zig").core.atomic.Atomic;

pub const Thread = struct {
    pub const Handle = system.HANDLE;

    pub fn spawn(
        comptime entryFn: fn(Handle, usize) void,
        parameter: usize,
        stack_size: u32,
    ) !Handle {
        const Spawner = struct {
            param: usize,
            handle: atomic.Atomic(system.HANDLE),

            const Self = @This();

            fn wait(self: *Self) void {
                const key = @ptrCast(*align(4) const c_void, self);
                switch (system.NtWaitForKeyedEvent(null, key, system.FALSE, null)) {
                    system.STATUS_SUCCESS => {},
                    else => unreachable,
                }
            }

            fn wake(ptr: *Self) void {
                const key = @ptrCast(*align(4) const c_void, self);
                switch (system.NtReleaseKeyedEvent(null, key, system.FALSE, null)) {
                    system.STATUS_SUCCESS => {},
                    else => unreachable,
                }
            }

            fn entry(raw_arg: system.PVOID) callconv(.C) system.DWORD {
                const self = @ptrCast(*Self, @alignCast(@alignOf(Self), raw_arg));
                self.wait();

                const handle = self.handle.load(.acquire);
                const param = self.param;
                self.wake();

                entryFn(handle, param);
                return 0;
            }
        };

        var spawner: Spawner = undefined;
        const handle = system.CreateThread(
            null,
            stack_size,
            Spawner.entry,
            @ptrCast(system.LPVOID, &spawner);
            0,
            null,
        ) orelse return error.SpawnError;

        spawner.param = parameter;
        spawner.handle.store(.release);
        spawner.wake();

        spawner.wait();
        return handle;
    }

    pub fn join(handle: Handle) void {
        if (system.WaitForSingleObject(handle, system.INFINITE) != system.STATUS_SUCCESS)
            unreachable;
        if (system.CloseHandle(handle) != TRUE)
            unreachable;
    }

    pub fn getCpuCount() u16 {
        var system_info: system.SYSTEM_INFO = undefined;
        system.GetSystemInfo(&system_info);
        return @intCast(u16, system_info.dwNumberOfProcessors);
    }
};