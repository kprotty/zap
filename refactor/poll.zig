const std = @import("std");
const Net = @import("net.zig");
const builtin = @import("builtin");
const Task = @import("sched.zig").Node.Task;

const os = std.os;
const system = os.system;
const IoStream = Net.IoStream;
const Handle = Net.Backend.Handle;

pub const Poller = switch (builtin.os) {
    .linux => Epoll,
    .windows => Iocp,
    .macosx, .freebsd, .netbsd => Kqueue,
    else => @compileError("Platform not supported"),
};

const Iocp = struct {
    iocp: Handle,

    pub fn init(self: *@This()) !void {
        try Net.Backend.initAll();
        self.iocp = try system.CreateIoCompletionPort(system.INVALID_HANDLE_VALUE, null, undefined, 1);
    }

    pub fn deinit(self: *@This()) void {
        Net.Backend.deinitAll();
        system.CloseHandle(self.iocp);
    }

    pub fn notify(self: *@This(), task: *Task) !void {
        _ = try system.PostQueueCompletionStatus(self.iocp, undefined, @ptrToInt(task), null);
    }

    pub fn register(self: *@This(), handle: Handle, stream: *IoStream) !void {
        _ = try system.CreateIoCompletionPort(handle, self.iocp, @ptrCast(system.ULONG_PTR, stream), 1);
    }

    pub fn poll(self: *@This(), blocking: bool) !?*Task {
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
            // HACK: hEvent contains the IoStream.(Readable|Writeable) flags.
            // relies on the fact that the NT kernel doesnt touch OVERLAPPED.hEvent
            for (events[0..events_found]) |event| {
                const flags = switch (event.lpOverlapped.Internal == 0) {
                    true => @truncate(u2, @ptrToInt(event.lpOverlapped.hEvent)),
                    false => IoStream.Disposable,
                };
                if (@ptrCast(*IoStream, event.lpCompletionKey).signal(flags, event.dwNumberOfBytesTransferred)) |new_task| {
                    task.link = task_list;
                    task_list = task;
                }
            }
            return task_list;
        } else {
            return system.unexpectedError(system.kernel32.GetLastError());
        }
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
};

const Kqueue = struct {
    const empty_events = ([*]os.Kevent)(undefined)[0..0];
    kqueue: Handle,

    pub fn init(self: *@This()) !void {
        self.kqueue = try std.os.kqueue();

        var events: [1]os.Kevent = undefined;
        @memset(@ptrCast([*]u8, events.ptr), 0, @sizeOf(os.Kevent));
        events[0].filter = os.EVFILT_USER;
        events[0].flags = os.EV_ADD | os.EV_CLEAR;
        _ = try std.os.kevent(self.kqueue, events[0..], empty_events, null);
    }

    pub fn deinit(self: *@This()) void {
        os.close(self.kqueue);
    }

    pub fn notify(self: *@This(), task: *Task) !void {
        var events: [1]os.Kevent = undefined;
        @memset(@ptrCast([*]u8, events.ptr), 0, @sizeOf(os.Kevent));
        events[0].filter = os.EVFILT_USER;
        events[0].fflags = os.NOTE_TRIGGER;
        events[0].udata = @ptrToInt(task);
        _ = try std.os.kevent(self.kqueue, events[0..], empty_events, null);
    }

    pub fn register(self: *@This(), handle: Handle, stream: *IoStream) !void {
        var events: [2]os.Kevent = undefined;
        @memset(@ptrCast([*]u8, events.ptr), 0, @sizeOf(os.Kevent));
        events[0].filter = os.EVFILT_READ;
        events[0].udata = @ptrToInt(stream);
        events[0].flags = os.EV_ADD | os.EV_CLEAR;
        events[1] = events[0];
        events[1].filter = os.EVFILT_WRITE;
        _ = try os.kevent(self.kqueue, events[0..], empty_events, null);
    }

    pub fn poll(self: *@This(), blocking: bool) !?*Task {
        return Posix.poll(self, 64, blocking, packed struct {
            inner: os.Kevent,

            pub fn poll(poller: *Poller, events: []@This(), timeout: ?*const os.timespec) !usize {
                return try std.os.kevent(self.kqueue, empty_events, events, timeout);
            }

            pub fn getTask(self: @This(), poller: *Poller) *Task {
                const has_error = (self.inner.flags & (os.EV_EOF | os.EV_ERROR)) != 0;
                return switch (self.filter) {
                    os.EVFILT_USER => @intToPtr(*Task, self.inner.udata),
                    os.EVFILT_READ => @intToPtr(*IoStream, self.inner.udata)
                        .signal(if (has_error) IoStream.Disposable else IoStream.Readable, @truncate(u32, self.inner.data)),
                    os.EVFILT_WRITE => @intToPtr(*IoStream, self.inner.udata)
                        .signal(if (has_error) IoStream.Disposable else IoStream.Writeable, @truncate(u32, self.inner.data)),
                    else => null,
                };
            }
        });
    }
};

const Epoll = struct {
    epoll_fd: Handle,
    event_fd: Handle,

    pub fn init(self: *@This()) !void {
        self.epoll_fd = try os.epoll_create1(os.EPOLL_CLOEXEC);
        self.event_fd = try os.eventfd(0, os.EFD_NONBLOCK | os.EFD_CLOEXEC);
        try self.register(self.event_fd, @intToPtr(*IoStream, @ptrToInt(self)));
    }

    pub fn deinit(self: *@This()) void {
        os.close(self.event_fd);
        os.close(self.epoll_fd);
    }

    pub fn notify(self: *@This(), task: *Task) !void {
        var value = @intCast(u64, @ptrToInt(task));
        try os.write(self.event_fd, @ptrCast([*]u8, &value)[0..@sizeOf(u64)]);
    }

    pub fn register(self: *@This(), handle: Handle, stream: *IoStream) !void {
        // event_fd doesnt need to listen to writable events (it should always be writeable)
        const EPOLLOUT = if (handle == self.event_fd) 0 else os.EPOLLOUT;
        var event = os.epoll_event {
            .data = os.epoll_data { .ptr = @ptrToInt(stream) },
            .events = os.EPOLLRDHUP | os.EPOLLET | os.EPOLLIN | EPOLLOUT,
        };
        try os.epoll_ctl(self.epoll_fd, os.EPOLL_CTL_ADD, handle, &event);
    }

    pub fn poll(self: *@This(), blocking: bool) !?*Task {
        return Posix.poll(self, 128, blocking, packed struct {
            inner: system.epoll_event,

            pub fn poll(poller: *Poller, events: []@This(), timeout: ?*const os.timespec) !usize {
                // have to implement manually since epoll_wait in std.os doesnt throw errors
                const num_events = @intCast(u32, events.len);
                const timeout_ms = if (timeout) |t| 0 else -1;
                while (true) {
                    const events_found = system.epoll_wait(poller.epoll_fd, events.ptr, num_events, timeout_ms);
                    switch (os.errno(events_found)) {
                        0 => return @intCast(usize, events_found),
                        os.EINTR => continue,
                        os.EBADF => return error.InvalidPollDescriptor,
                        os.EFAULT => return error.InvalidEventsMemory,
                        os.EINVAL => return error.InvalidDescriptorOrEventSize,
                        else => unreachable,
                    }
                }
            }

            pub fn getTask(self: @This(), poller: *Poller) *Task {
                // fetch tasks from an IoStream if not that of the poller
                if (self.inner.data.ptr != @ptrToInt(poller)) {
                    var flags = IoStream.Disposable;
                    if ((self.inner.events & os.EPOLLIN) != 0)
                        flags |= IoStream.Readable;
                    if ((self.inner.events & os.EPOLLOUT) != 0)
                        flags |= IoStream.Writeable;
                    if ((self.inner.events & (os.EPOLLERR | os.EPOLLHUP | os.EPOLLRDHUP)) != 0)
                        flags = IoStream.Disposable;
                    return @intToPtr(*IoStream, self.inner.data.ptr).signal(flags, 0);
                }

                // read the task pointer from the event_fd
                var value: [@sizeOf(u64)] align(@alignOf(*Task)) u8 = undefined;
                const bytes_read = os.read(poller.event_fd, value[0..]) catch unreachable;
                std.debug.assert(bytes_read == value.len);
                return @bytesToSlice(*Task, bytes)[0];
            }
        });
    }
};

const Posix = struct {
    pub fn poll(poller: var, comptime num_events: usize, blocking: bool, comptime Event: type) !?*Task {
        var task_list: ?*Task = null;
        var events_found: usize = undefined;
        var events: [num_events]Event = undefined;
        var timeout = os.timespec { .tv_sec = 0, .tv_nsec = 0 },

        // poll for events, if blocking then dont stop until theres at least 1
        while (true) {
            events_found = try Event.poll(poller, events[0..], if (blocking) null else &timeout);
            if (events_found > 1 or !blocking)
                break;
        }

        // build a linked-list stack of Tasks found in the events if any
        for (events[0..events_found]) |event| {
            if (event.getTask(poller)) |new_task| {
                (if (new_task.link) |next_task| next_task else new_task).link = task_list;
                task_list = new_task;
            }
        }

        return task_list;
    }
};