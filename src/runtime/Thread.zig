const std = @import("std");

pub const Thread = if (std.builtin.os.tag == .windows)
    WindowsThread
else if (std.builtin.link_libc)
    PosixThread
else if (std.builtin.os.tag == .linux)
    LinuxThread
else
    @compileError("Platform not supported");

const WindowsThread = struct {
    handle: std.os.windows.HANDLE,

    const Spawner = struct {
        state: State = .empty,
        data: [2]usize = undefined,

        const Futex = @import("./Futex.zig").Futex;
        const State = enum(u32) {
            empty,
            put,
            got,
        };

        fn get(self: *@This()) [2]usize {
            const ptr = @ptrCast(*const u32, &self.state);
            while (@atomicLoad(State, &self.state, .Acquire) == .empty)
                Futex.wait(ptr, @enumToInt(State.empty), null) catch unreachable;

            const data = self.data;
            @atomicStore(State, &self.state, .got, .Release);
            Futex.wake(ptr, 1);

            return data;
        }

        fn set(self: *@This(), data: [2]usize) void {
            self.data = data;
            @atomicStore(State, &self.state, .put, .Release);

            const ptr = @ptrCast(*const u32, &self.state);
            while (@atomicLoad(State, &self.state, .Acquire) == .put)
                Futex.wait(ptr, @enumToInt(State.put), null) catch unreachable;
        }
    };

    pub fn spawn(comptime entryFn: fn(@This(), usize) void, context: usize) bool {
        const Wrapper = struct {
            fn entry(raw_arg: std.os.windows.LPVOID) callconv(.C) std.os.windows.DWORD {
                const spawner = @ptrCast(*Spawner, @alignCast(@alignOf(Spawner), raw_arg));
                const data = spawner.get();

                const _handle = @intToPtr(std.os.windows.HANDLE, data[0]);
                const _context = data[1];

                entryFn(.{ .handle = _handle }, _context);
                return 0;
            }
        };
        
        var spawner = Spawner{};
        const handle = std.os.windows.kernel32.CreateThread(
            null,
            0, // use default stack size
            Wrapper.entry,
            @intToPtr(std.os.windows.LPVOID, &spawner),
            0,
            null,
        ) orelse return false;

        spawner.set([_]usize{ @ptrToInt(handle), context });
        return true;
    }

    pub fn join(self: @This()) void {
        std.os.windows.WaitForSingleObjectEx(self.handle, std.os.windows.INFINITE, null) catch unreachable;
        std.os.windows.CloseHandle(self.handle);
    }
};

const PosixThread = struct {
    tid: std.c.pthread_t,

    pub fn spawn(comptime entryFn: fn(@This(), usize) void, context: usize) bool {
        const Wrapper = struct {
            fn entry(ctx: ?*c_void) callconv(.C) ?*c_void {
                entryFn(.{ .tid = std.c.pthread_self() }, @ptrToInt(ctx));
                return null;
            }
        };

        var handle: std.c.pthread_t = undefined;
        const rc = std.c.pthread_create(
            &handle,
            null,
            Wrapper.entry,
            @intToPtr(?*c_void, context),
        );

        return rc == 0;
    }

    pub fn join(self: @This()) void {
        const rc = std.c.pthread_join(self.tid, null);
        std.debug.assert(rc == 0);
    }
};

const LinuxThread = struct {
    pub fn spawn(comptime entryFn: fn(@This(), usize) void, context: usize) bool {
        @compileError("TODO");
    }

    pub fn join(self: @This()) void {
        @compileError("TODO");
    }
};