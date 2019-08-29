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
            var events: [64]std.os.Kevent = undefined;
            var timeout = std.os.timespec { .tv_sec = 0, .tv_nsec = 0 };

            while (true) {
                events_found = try std.os.kevent(
                    self.kqueue,
                    ([*]std.os.Kevent)(undefined)[0..0],
                    events[0..],
                    if (blocking) null else &timeout,
                );
                if (events_found >= 1 or !blocking)
                    break;
            }

            for (events[0..events_found]) |event| {
                var flags: u2 = 0;
                if ((event.filter & std.os.EVFILT_READ) != 0)
                    flags |= IoChannel.Readable;
                if ((event.filter & std.os.EVFILT_WRITE) != 0)
                    flags |= IoChannel.Writeable;
                if ((event.flags & (std.os.EV_EOF | std.os.EV_ERROR)) != 0)
                    flags = 0;
                if (@intToPtr(*IoChannel, event.udata).signal(flags, event.data)) |new_task| {
                    if (new_task.link) |other_task| {
                        other_task.link = task_list;
                    } else {
                        new_task.link = task_list;
                    }
                    task_list = new_task;
                }
            }

            return task_list;
        }
    },
    .linux => struct {
        epoll: i32,

        pub fn init(self: *@This()) !void {
            self.epoll = try std.os.epoll_create1(std.os.EPOLL_CLOEXEC);
        }

        pub fn deinit(self: *@This()) void {
            std.os.close(self.epoll);
        }

        pub fn poll(self: *@This(), blocking: bool) !?*Task {
            var events_found: usize = 0;
            var task_list: ?*Task = null;
            var events: [128]std.os.epoll_event = undefined;

            while (true) {
                events_found = try std.os.epoll_wait(
                    self.epoll,
                    events[0..],
                    if (blocking) -1 else 0,
                );
                if (events_found >= 1 or !blocking)
                    break;
            }

            for (events[0..events_found]) |event| {
                var flags: u2 = 0;
                if ((event.filter & std.os.EPOLLIN) != 0)
                    flags |= IoChannel.Readable;
                if ((event.filter & std.os.EPOLLOUT) != 0)
                    flags |= IoChannel.Writeable;
                if ((event.flags & (std.os.EPOLLERR | std.os.EPOLLHUP | std.os.EPOLLRDHUP)) != 0)
                    flags = 0;
                if (@intToPtr(*IoChannel, event.udata).signal(flags, event.data)) |new_task| {
                    if (new_task.link) |other_task| {
                        other_task.link = task_list;
                    } else {
                        new_task.link = task_list;
                    }
                    task_list = new_task;
                }
            }

            return task_list;
        }
    },
    .windows => struct {
        const system = std.os.windows;
        iocp: system.HANDLE,

        pub init(self: *@This()) !void {
            self.iocp = try system.CreateIoCompletionPort(system.INVALID_HANDLE_VALUE, null, undefined, 1);
        }

        pub fn deinit(self: *@This()) void {
            system.CloseHandle(self.iocp);
        }

        pub fn poll(self: *@This(), blocking: bool) ?*Task {
            var task_list: ?*Task = null;
            var events_found: system.ULONG = undefined;
            var events: [64]OVERLAPPED_ENTRY = undefined;
            
            if (GetQueuedCompletionStatusEx(
                self.iocp,
                events[0..].ptr,
                @intCast(system.ULONG, events.len),
                &events_found,
                if (blocking) system.INFINITE else 0,
                system.FALSE,
            ) == system.TRUE) {
                // task stored in hEvent, bytestransffered stored in InternalHigh
                for (events[0..events_found]) |event| {
                    event.lpOverlapped.InternalHigh = @intToPtr(system.ULONG_PTR, usize(event.dwNumberOfBytesTransferred));
                    const task = @ptrCast(*Task, @alignCast(@alignOf(*Task), event.lpOverlapped.hEvent));
                    task.link = task_list;
                    task_list = task;
                }
            }

            return task_list;
        }

        const OVERLAPPED_ENTRY = extern struct {
            lpCompletionKey: system.ULONG_PTR,
            lpOverlapped: ?*system.OVERLAPPED,
            Internal: system.ULONG_PTR,
            dwNumberOfBytesTransferred: system.DWORD,
        };

        extern "kernel32" stdcallcc fn GetQueuedCompletionStatusEx(
            CompletionPort: system.HANDLE,
            lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
            ulCount: system.ULONG,
            ulNumEntriesRemoved: system.PULONG,
            dwMilliseconds: system.DWORD,
            fAlertable: system.BOOL,
        ) system.BOOL;
    },
    else => @compileError("Unsupported OS"),
};

pub const Socket = switch (builtin.os) {
    .windows => struct {

    },
    else => struct {
        
    };
};

const IoChannel = struct {
    pub const Readable  = u2(0b01);
    pub const Writeable = u2(0b10);

    input: usize,
    output: usize,

    pub fn init(self: *@This()) void {
        self.input = 0;
        self.output = 0;
    }

    pub fn signal(self: *@This(), flags: u2, data: usize) ?*Task {
        const write_task = if ((flags & Writeable)) self.signalEvent(&self.output, data) else null;
        const read_task = if ((flags & Readable)) self.signalEvent(&self.input, data) else null;
        if (write_task) |task| task.link = read_task;
        return write_task orelse read_task;
    }

    fn signalEvent(self: *@This(), state: *usize, data: usize) ?*Task {
        // TODO
    }

    pub fn inline waitForInput(self: *@This()) ?usize {
        return self.wait(&self.input);
    }

    pub fn inline waitForOutput(self: *@This()) ?usize {
        return self.wait(&self.output);
    }

    fn wait(self: *@This(), state: *usize) ?usize {
        // TODO
    }
};