const std = @import("std");
const builtin = @import("builtin");
const Task = @import("sched.zig").Node.Task;

pub const Handle = switch (builtin.os) {
    .windows => std.os.windows.HANDLE,
    else => i32,
};

pub const Poller = switch (builtin.os) {
    .macosx, .freebsd, .netbsd => struct {
        kqueue: i32,

        pub fn init(self: *@This()) !void {
            self.kqueue = try std.os.kqueue();
        }

        pub fn deinit(self: *@This()) void {
            std.os.close(self.kqueue);
        }

        pub fn poll(self: *@This(), blocking: bool) !?*Task {
            var events_found: usize = 0;
            var task_list: ?*Task = null;
            var events: [64]os.Kevent = undefined;
            var timeout = os.timespec { .tv_sec = 0, .tv_nsec = 0 };

            while (true) {
                events_found = try os.kevent(
                    self.kqueue,
                    ([*]os.Kevent)(undefined)[0..0],
                    events[0..],
                    if (blocking) null else &timeout,
                );
                if (events_found > 1 or !blocking)
                    break;
            }

            while (events_found > 0) : (events_found -= 1) {
                var flags: u32 = 0;
                const event = &events[events_found - 1];
                if ((event.filter & os.EVFILT_READ) != 0)
                    flags |= Socket.Readable;
                if ((event.filter & os.EVFILT_WRITE) != 0)
                    flags |= Socket.Writeable;
                if ((event.flags & (os.EV_EOF | os.EV_ERROR)) != 0)
                    flags |= Socket.Disposable;

                if (switch (event.udata & 1) {
                    1 => try @intToPtr(*Socket.Duplex, event.udata & ~usize(1)).poll(flags, event.data),
                    else => try @intToPtr(*Socket.Channel, event.udata).poll(flags, event.data),
                }) |task| {
                    task.link = task_list;
                    task_list = task;
                }
            }

            return task_list;
        }
    },
    .linux => struct {
        
    },
    .windows => struct {

    },
    else => @compileError("Unsupported OS"),
};

pub const Socket = switch (builtin.os) {
    .windows => struct {

    },
    else => struct {
        fd: i32,
        stream: Duplex,

        pub const Readable   = u32(0b001);
        pub const Writeable  = u32(0b010);
        pub const Disposable = u32(0b100);

        pub const Duplex = struct {
            input: Channel,
            output: Channel,

            pub fn poll(self: *@This(), flags: u32, data: usize) !?*Task {
                const read_task = if ((flags & Readable) != 0) try self.output.poll(flags, data) else null;
                const write_task = if ((flags & Writable) != 0) try self.input.poll(flags, data) else null;
                if (write_task) |task| task.link = read_task;
                return write_task orelse read_task;
            }
        };

        pub const Channel = struct {
            state: usize,
            
            pub fn poll(self: *@This(), flags: u32, data: usize) !?*Task {
                // swaps, uses .Release
            }

            pub fn recv(self: *@This()) usize {
                // suspends, uses .Acquire
            }
        };

        pub fn init(self: *@This(), ) !void {

        }
    };
};