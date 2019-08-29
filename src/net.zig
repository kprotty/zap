const std = @import("std");
const builtin = @import("builtin");
const Task = @import("sched.zig").Node.Task;

pub const Handle = Backend.Handle;
pub const Poller = Backend.Poller;
pub const Socket = Backend.Socket;

const os = std.os;
const system = os.system;
const Backend = switch (builtin.os) {
    .linux => Epoll,
    .windows => Iocp,
    .macosx, .freebsd, .netbsd => Kqueue,
    else => @compileError("Platform not supported"),
};

const Kqueue = struct {
    pub const Handle = Posix.Handle;

    pub const Poller = struct {
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
};

const Epoll = struct {
    pub const Handle = Posix.Handle;

    pub const Poller = struct {
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
};

const Posix = struct {
    pub const Handle = i32;

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

const Iocp = struct {
    pub const Handle = system.HANDLE;

    pub const Poller = struct {
        iocp: Handle,

        pub fn init(self: *@This()) !void {
            try Socket.initAll();
            self.iocp = try system.CreateIoCompletionPort(system.INVALID_HANDLE_VALUE, null, undefined, 1);
        }

        pub fn deinit(self: *@This()) void {
            Socket.deinitAll();
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

    const Socket = struct {
        pub fn initAll() !void {
            // TODO: WSAStartup(), WSAIocl() -> AcceptEx, ConnectEx
        }

        pub fn deinitAll() void {
            // TODO: WSACleanup()
        }
    };
};

const IoStream = struct {
    pub const Readable   = u2(0b01);
    pub const Writeable  = u2(0b10);
    pub const Disposable = u2(0b00);

    reader: Event,
    writer: Event,

    pub fn init(self: *@This()) void {
        self.reader.init();
        self.writer.init();
    }

    pub fn signal(self: *@This(), flags: u2, data: u32) ?*Task {
        var reader_task: ?*Task = null;
        var writer_task: ?*Task = null;

        if (flags == Disposable) {
            writer_task = self.writer.signal(Event.Close);
            reader_task = self.reader.signal(Event.Close)
        } else {
            if ((flags & Writeable) != 0)
                writer_task = self.writer.signal(Event.EncodeReady(data));
            if ((flags & Readable) != 0)
                reader_task = self.reader.signal(Event.EncodeReady(data));  
        }

        // return any tasks found. Try and link them together if theres multiple.
        if (writer_task) |task|
            task.link = reader_task;
        return writer_task orelse reader_task;
    }

    const Event = struct {
        /// Thread safe mechanism for event notification and task wakeup.
        /// `state` begins as "Empty" and event pollers signal by setting it to either "Close" or "Ready".
        /// Under "Ready", the upper bits are used as a hint to the IO waiting for event for how many bytes to use.
        /// The upper bits are set only on kevent as they cant be used to know exactly how many bytes to read as an optimization.
        /// If an IO operation fails to consume a "Close" or "Ready" event, it then starts to suspend.
        /// Once suspended, it tries and to consume the event once more just in case it was set during the process.
        /// If that fails as well, the `state` is set to "Waiting" indicating that the upper bits represent a `Task` pointer.
        /// NOTE: The reason these tag states are 2-bits large is that maximum value we can fit into a 32bit or 64bit aligned pointer. 
        pub const Empty   = usize(0b11);
        pub const Close   = usize(0b10);
        pub const Ready   = usize(0b01);
        pub const Waiting = usize(0b00);
        state: usize,

        pub fn init(self: *@This()) void {
            self.state = Empty;
        }

        pub inline fn EncodeReady(data: u32) usize {
            return (@intCast(usize, data) << 2) | Ready;
        }

        pub inline fn DecodeReady(data: usize) u32 {
            return @truncate(u32, data >> 2);
        }

        pub fn signal(self: *@This(), data: usize) ?*Task {
            // PRODUCER: update the state & return a Task if there was any waiting 
            @fence(.Release);
            const state = @atomicRmw(usize, &self.state, .Xchg, data, .Monotonic);
            return if ((state & 0b11) == Waiting) @intToPtr(*Task, state) else null;
        }

        fn consumeSignalWith(self: *@This(), update: usize) !?usize {
            var state = @atomicLoad(usize, &self.state, .Monotonic);
            while (true) {
                switch ((state & 0b11)) {
                    Empty => return null,
                    Waiting => return error.ContendedWaiting,
                    Ready, Close => if (@cmpxchgWeak(usize, &self.state, state, update, .Monotonic, .Monotonic)) |new_state| {
                        state = new_state;
                        continue;
                    } else return state,
                    else => unreachable,
                }
                @fence(.Acquire);
            }
        }

        pub async fn wait(self: *@This()) !?u32 {
            while (true) {
                // CONSUMER: try and consume an event without blocking
                if (try consumeSignalWith(Empty)) |state|
                    return if ((state & 0b11) == Ready) DecodeReady(state) else null;

                // no event was found, try and suspend / reschedule until it is woken up by `signal()`
                // check once more if an event was set during the suspend block before rescheduling
                var result: !?usize = null;
                suspend {
                    var task = Task { .link = null, .frame = @frame() };
                    if (consumeSignalWith(@ptrToInt(task.frame) | Waiting) catch |e| {
                        result = e;
                        resume task.frame;
                    }) |state| {
                        result = state;
                        resume task.frame;
                    } else {
                        task.reschedule();
                    }
                }

                // try and return a result if it was set, else jump back and try to consume the event again
                if (try result) |state|
                    return if ((state & 0b11) == Ready) DecodeReady(state) else null;
            }
        }
    };
};
