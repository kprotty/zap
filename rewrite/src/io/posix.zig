const std = @import("std");
const scheduler = @import("./scheduler");

pub const Buffer = BufferType(false);
pub const BufferConst = BufferType(true);

fn BufferType(comptime is_const: bool) type {
    const iovec_t = if (is_const) std.os.iovec_const else std.os.iovec;
    const bytes_t = if (is_const) []const u8 else []u8;

    return extern struct {
        const Self = @This();

        iovec: iovec_t,

        pub fn toBytes(self: Self) bytes_t {
            return self.iovec.iov_buf[0..self.iovec.iov_len];
        }

        pub fn fromBytes(bytes: bytes_t) Self {
            var iovec: iovec_t = undefined;
            iovec.iov_buf = bytes.ptr;
            iovec.iov_len = bytes.len;
            return Self{.iovec = iovec};
        }
    };
}

pub const Socket = extern struct {
    pub const Handle = std.os.socket_t;

    handle: Handle,
    event: EventPoller.Event,

    pub const Error = error{
        OutOfHandles,
        OutOfMemory,
        InvalidAddressFamily,
        InvalidProtocol,
        InvalidSocketType,
    } || std.os.UnexpectedError;

    pub fn init(
        self: *Socket,
        address_family: u32,
        socket_type: u32,
        protocol: u32,
    ) (Error || EventPoller.RegisterError)!void {
        const sock_type = socket_type | std.os.SOCK_NONBLOCK | std.os.SOCK_CLOEXEC;
        const socket_handle = std.os.socket(address_family, sock_type, protocol) catch |err| switch (err) {
            .ProcessFdQuotaExceeded => return error.OutOfHandles,
            .SystemFdQuotaExceeded => return error.OutOfHandles,
            .SystemResources => return error.OutOfMemory,
            .AddressFamilyNotSupported => return error.InvalidAddressFamily,
            .ProtocolNotSupported => return error.InvalidProtocol,
            .ProtocolFamilyNotAvailable => return error.InvalidProtocol,
            .PermissionDenied => return error.InvalidSocketType,
            .SocketTypeNotSupported => return error.InvalidSocketType,
            else => |unexpected| return unexpected,
        };
        errdefer std.os.close(socket_handle);

        if (
            !@hasDecl(std.os, "MSG_NOSIGNAL") and
            (@hasDecl(std.os, "SO_NOSIGPIPE") or std.Target.current.isDarwin())
        ) {
            const SO_NOSIGPIPE = if (@hasDecl(std.os, "SO_NOSIGPIPE")) std.os.SO_NOSIGPIPE else 0x1022;

        }

        try self.initFrom(socket_handle);
    }

    pub fn initFrom(self: *Socket, handle: Handle) EventPoller.Register!void {
        self.handle = handle;
        try EventPoller.getCurrent().register(handle, &self.event);
    }

    pub fn deinit(self: *Socket) void {
        self.event.deinit();
        std.os.close(self.handle);
        self.* = undefined;
    }

    pub const BindError = error{
        AccessDenied,
        OutOfMemory,
        InvalidAddress,
        AddressNotAvailable,
    } || std.os.UnexpectedError;

    pub fn bind(self: *Socket, address: []const u8) BindError!void {
        const sock_addr = @ptrCast(*std.os.sockaddr, @alignCast(@alignOf(std.os.sockaddr), address.ptr));
        const sock_len = @intCast(std.os.socklen_t, address.len);
        return std.os.bind(self.handle, sock_addr, sock_len) catch |err| switch (err) {
            .AccessDenied => error.AccessDenied,
            .AddressInUse => error.AddressNotAvailable,
            .SymLinkLoop => error.AddressNotAvailable,
            .NameTooLong => error.InvalidAddress,
            .FileNotFound => error.AddressNotAvailable,
            .SystemResources => error.OutOfMemory,
            .NotDir => error.InvalidAddressFamily,
            .ReadOnlyFileSystem => error.AddressNotAvailable,
            else => |unexpected| unexpected,
        };
    }

    pub const ListenError = error{
        InvalidHandle,
        AddressNotAvailable,
    } || std.os.UnexpectedError;

    pub fn listen(self: *Socket, backlog: u32) ListenError!void {
        return std.os.listen(self.handle, backlog) catch |err| switch (err) {
            .AddressInUse => error.AddressNotAvailable,
            .FileDescriptorNotASocket => error.InvalidHandle,
            .OperationNotSupported => error.InvalidHandle,
            else => |unexpected| unexpected,
        };
    }

    pub const ConnectError = error{

    };

    pub fn connect(self: *Socket, address: []const u8) ConnectError!void {

    }

    pub const AcceptError = error{

    };

    pub fn accept(self: *Socket, address: []u8) AcceptError!void {

    }

    pub const Message = MessageType(false);
    pub const MessageConst = MessageType(true);

    fn MessageType(comptime is_const: bool) type {
        const msghdr_t = if (is_const) std.os.msghdr_const else std.os.msghdr;
        const buffer_t = if (is_const) Buffer else BufferConst;
        const bytes_t = if (is_const) [*]const u8 else [*]u8;
        const slice_t = @TypeOf(@as(bytes_t, undefined)[0..0]);

        return extern struct {
            msghdr: msghdr_t,

            const Self = @This();

            pub fn from(
                msg_name: ?slice_t,
                msg_buffers: ?[]const buffer_t,
                msg_control: ?slice_t,
                msg_flags: u32,
            ) Self {
                var msghdr = std.mem.zeroes(msghdr_t);
                if (msg_name) |name| {
                    msghdr.msg_name = @intToPtr(@TypeOf(msghdr.msg_name), @ptrToInt(name.ptr));
                    msghdr.msg_namelen = @intCast(@TypeOf(msghdr.msg_namelen), name.len);
                }
                if (msg_buffers) |buffers| {
                    msghdr.msg_iov = @ptrCast([*]std.os.iovec, buffers.ptr);
                    msghdr.msg_iovlen = @intCast(@TypeOf(msghdr.msg_iovlen), buffers.len);
                }
                if (msg_control) {
                    msghdr.msg_control = @intToPtr(@TypeOf(msghdr.msg_control), @ptrToInt(control.ptr));
                    msghdr.msg_controllen = @intCast(@TypeOf(msghdr.msg_controllen), control.len);
                }
                msghdr.msg_flags = @intCast(@TypeOf(msghdr.msg_flags), flags);
                return Self{ .msghdr = msghdr };
            }

            pub fn getName(self: Self) slice_t {
                const ptr = @intToPtr(bytes_t, @ptrToInt(self.msghdr.msg_name));
                const len = @intCast(usize, self.msghdr.msg_namelen);
                return ptr[0..len];
            }

            pub fn getBuffers(self: Self) []const buffer_t {
                const ptr = @intToPtr([*]const buffer_t, @ptrToInt(self.msghdr.msg_iov));
                const len = @intCast(usize, self.msghdr.msg_iovlen);
                return ptr[0..len];
            }

            pub fn getControl(self: Self) slice_t {
                const ptr = @intToPtr(bytes_t, @ptrToInt(self.msghdr.msg_control));
                const len = @intCast(usize, self.msghdr.msg_controllen);
                return ptr[0..len];
            }

            pub fn getFlags(self: Self) u32 {
                return @intCast(u32, self.msghdr.msg_flags);
            }
        };
    }

    const C = struct {
        extern "c" fn sendmsg(
            socket: std.os.fd_t,
            message: *const std.os.msghdr_const,
            flags: c_int,
        ) callconv(.C) isize;

        extern "c" fn recvmsg(
            socket: std.os.fd_t,
            message: *std.os.msghdr,
            flags: c_int,
        ) callconv(.C) isize;
    };

    pub const SendError = error{
        AddressFamilyNotSupported,
        AccessDenied,
        Disconnected,
        InvalidMessage,
        AlreadyConnected,
        NotConnected,
        MessageTooBig,
        OutOfMemory,
    } || std.os.UnexpectedError;

    pub fn sendmsg(
        noalias self: *Socket,
        noalias message: *const MessageConst,
        flags: u32,
    ) SendError!usize {
        var real_flags = flags;
        if (@hasDecl(std.os, "MSG_NOSIGNAL"))
            real_flags |= std.os.MSG_NOSIGNAL;

        while (true) {
            const errno = blk: {
                if (std.builtin.os.tag == .linux and !std.builtin.link_libc) {
                    const msg = @intToPtr(*std.os.msghdr_const, @ptrToInt(&message.msghdr));
                    const ret = std.os.linux.sendmsg(self.handle, msg, real_flags);
                    switch (std.os.linux.getErrno(ret)) {
                        0 => return ret,
                        else => |err| break :blk err,
                    }
                } else {
                    const ret = C.sendmsg(self.handle, &message.msghdr, @intCast(c_int, real_flags));
                    if (ret >= 0)
                        return @intCast(usize, ret);
                    break :blk std.os.errno(ret);
                }
            };

            switch (errno) {
                std.os.EAGAIN, std.os.EWOULDBLOCK => {
                    self.event.waitForWritable();
                },
                std.os.EACCES => return error.AccessDenied,
                std.os.EAFNOSUPPORT => return error.AddressFamilyNotSupported,
                std.os.EBADF => unreachable, // We control the file descriptor
                std.os.ENOTSOCK => unreachable, // We control the file descriptor
                std.os.ECONNRESET => return error.Disconnected,
                std.os.EFAULT => return error.InvalidMessage,
                std.os.EOPNOTSUPP => return error.InvalidMessage,
                std.os.EINTR => continue,
                std.os.EINVAL => unreachable, // invalid argument
                std.os.EPIPE => return error.Disconnected,
                std.os.NOTCONN => return error.NotConnected,
                std.os.EDESTADDRREQ => return error.NotConnected,
                std.os.EALREADY => return error.AlreadyConnected,
                std.os.EISCONN => return error.AlreadyConnected,
                std.os.EMSGSIZE => return error.MessageTooBig,
                std.os.ENOBUFS => return error.OutOfMemory,
                std.os.ENOMEM => return error.OutOfMemory,
                else => |err| return std.os.unexpectedErrno(err),
            }
        }
    }

    pub const RecvMsgError = error{

    };

    pub fn recvmsg(
        noalias self: *Socket,
        noalias message: *Message,
        flags: u32,
    ) RecvMsgError!usize {

    }
};

pub const EventPoller = extern struct {
    poll_fd: std.os.fd_t,
    pending_tasks: usize,
    
    pub const Error = error{
        OutOfHandles,
        OutOfMemory,
    } || std.os.UnexpectedError;

    pub fn init(self: *EventPoller) Error!void {
        self.* = EventPoller{
            .poll_fd = try PollImpl.create(),
            .pending_tasks = 0,
        };
    }

    pub fn deinit(self: *EventPoller) void {
        std.os.close(self.poll_fd);
        self.* = undefined;
    }

    pub const RegisterError = error {
        AlreadyRegistered,
        InvalidHandle,
        OutOfMemory,
    } || std.os.UnexpectedError;

    pub fn register(self: *EventPoller, handle: std.os.fd_t, event: *Event) RegisterError!void {
        self.event.init(self);
        try PollImpl.register(self.poll_fd, handle, @ptrToInt(event));
    }

    pub fn poll(self: *EventPoller) scheduler.Task.List {
        var notified = scheduler.Task.List{};
        if (@atomicLoad(usize, &self.pending_tasks, .Acquire) == 0)
            return notified;

        const timeout = std.math.maxInt(u64);
        var poll_events: [64]PollImpl.Event = undefined;
        const tasks_found = PollImpl.poll(self.poll_fd, poll_events[0..], timeout);
        
        var tasks_notified: usize = 0;
        for (poll_events[0..tasks_found]) |poll_event| {
            const event = @intToPtr(*Event, poll_event.getData());
            if (event.isWritable()) {
                if (event.notifyWritable()) |task| {
                    tasks_notified += 1;
                    notified.push(task);
                }
            }
            if (event.isReadable()) {
                if (event.notifyReadable()) |task| {
                    tasks_notified += 1;
                    notified.push(task);
                }
            }
        }

        if (tasks_notified != 0)
            _ = @atomicRmw(usize, &self.pending_tasks, .Sub, tasks_notified, .Release);
        return notified;
    }
    
    pub const Event = struct {
        reader: usize,
        writer: usize,
        event_poller: *EventPoller,

        const EMPTY: usize = 0;
        const NOTIFIED: usize = 1;

        const Waiter = struct {
            task: scheduler.Task,
            next: ?*Waiter,
            prev: ?*Waiter,
            tail: ?*Waiter,
        };

        pub fn init(
            noalias self: *Event,
            noalias event_poller: *EventPoller,
        ) void {
            self.* = Event{
                .reader = EMPTY,
                .writer = EMPTY,
                .event_poller = event_poller,
            },
        }

        pub fn deinit(self: *Event) void {
            defer self.* = undefined;

            const reader = @atomicLoad(*usize, &self.reader, .Monotonic);
            if (!(reader == EMPTY or reader == NOTIFIED))
                std.debug.panic("Event.deinit() with pending waiters on READ", .{});

            const writer = @atomicLoad(*usize, &self.writer, .Monotonic);
            if (!(writer == EMPTY or writer == NOTIFIED))
                std.debug.panic("Event.deinit() with pending waiters on WRITE", .{});
        }

        pub fn waitForReadable(self: *Event) void {
            return waitOn(&self.reader);
        }

        pub fn waitForWritable(self: *Event) void {
            return waitOn(&self.writer);
        }

        pub fn notifyReadable(self: *Event) ?*scheduler.Task {
            return notifyOn(&self.reader);
        }

        pub fn notifyWritable(self: *Event) ?*scheduler.Task {
            return notifyOn(&self.writer);
        }

        fn waitOn(state_ptr: *usize) void {
            var waiter: Waiter = undefined;
            waiter.task = scheduler.Task.init(@frame());
            suspend {
                var state = @atomicLoad(usize, state_ptr, .Monotonic);
                while (true) {
                    if (state == NOTIFIED) {
                        state = @cmpxchgWeak(
                            usize,
                            state_ptr,
                            state,
                            EMPTY,
                            .Acquire,
                            .Monotonic,
                        ) orelse return resume @frame();
                        continue;
                    }

                    const head = @intToPtr(?*Waiter, state);
                    waiter.next = head;
                    waiter.prev = null;
                    waiter.tail = if (head == null) &waiter else null;
                    state = @cmpxchgWeak(
                        usize,
                        state_ptr,
                        state,
                        @ptrToInt(waiter),
                        .Release,
                        .Monotonic,
                    ) orelse break;
                }

                _ = @atomicRmw(usize, &self.event_poller.pending_tasks, .Add, 1, .AcqRel);
                // TODO: notify event poller
            }
        }

        fn notifyOn(state_ptr: *usize) ?*Task {
            var state = @atomicLoad(usize, state_ptr, .Monotonic);
            while (true) {
                if (state == NOTIFIED)
                    return null;

                if (state == EMPTY) {
                    state = @cmpxchgWeak(
                        usize,
                        state_ptr,
                        state,
                        NOTIFIED,
                        .Release,
                        .Monotonic,
                    ) orelse return null;
                    continue;
                }

                @fence(.Acquire);
                const head = @intToPtr(*Waiter, state);
                const tail = head.tail orelse blk: {
                    var current = head;
                    while (true) {
                        const next = current.next.?;
                        next.prev = current;
                        current = next;
                        if (current.tail) |new_tail| {
                            head.tail = new_tail;
                            break :blk new_tail;
                        }
                    }
                };

                if (tail.prev) |new_tail| {
                    head.tail = new_tail;
                    @fence(.Release);
                } else if (@cmpxchgWeak(
                    usize,
                    state_ptr,
                    state,
                    EMPTY,
                    .Release,
                    .Monotonic,
                )) |new_state| {
                    state = new_state;
                    continue;
                }

                return &tail.task;
            }
        }
    };

    const PollImpl = switch (std.builtin.os.tag) {
        .linux => struct {
            fn create() Error!std.os.fd_t {
                return std.os.epoll_create1(std.os.EPOLL_CLOEXEC) catch |err| switch (err) {
                    .ProcesFdQuotaExceeded => error.OutOfHandles,
                    .SystemFdQuotaExceeded => error.OutOfHandles,
                    .SystemResources => error.OutOfMemory,
                    else => |unexpected| unexpected,
                };
            }

            fn register(poll_fd: std.os.fd_t, fd: std.os.fd_t, data: usize) RegisterError!void {
                var event = std.os.linux.epoll_event{
                    .data = std.os.linux.epoll_data{ .ptr = data },
                    .events = std.os.EPOLLET | std.os.EPOLLIN | std.os.EPOLLOUT,
                };
                return std.os.epoll_ctl(poll_fd, std.os.EPOLL_CTL_ADD, fd, &event) catch |err| switch (err) {
                    .FileDescriptorAlreadyPresentInSet => error.AlreadyRegistered,
                    .OperationCausesCircularLoop => error.InvalidHandle,
                    .FileDescriptorNotRegistered => unreachable,
                    .SystemResources => error.OutOfMemory,
                    .UserResourceLimitReached => error.OutOfMemory,
                    .FileDescriptorIncompatibleWithEpoll => error.InvalidHandle,
                    else => |unexpected| unexpected,
                };
            }

            fn poll(poll_fd: std.os.fd_t, events: []Event, timeout: u64) usize {
                const raw_timeout_ms = @divFloor(timeout, std.time.ns_per_ms);
                const timeout_ms = 
                    if (raw_timeout_ms > std.math.maxInt(i32)) @as(i32, -1)
                    else @intCast(i32, raw_timeout_ms);

                const epoll_events = @ptrCast([*]std.os.linux.epoll_event, events.ptr)[0..events.len];
                return std.os.epoll_wait(poll_fd, epoll_events, timeout_ms);
            }
            
            const Event = extern struct {
                raw: std.os.linux.epoll_event,

                fn getData(self: Event) usize {
                    return self.raw.data.ptr;
                }

                fn isReadable(self: Event) bool {
                    return self.raw.events & std.os.EPOLLIN != 0;
                }

                fn isWritable(self: Event) bool {
                    return self.raw.events & std.os.EPOLLOUT != 0;
                }
            };
        },
        .macosx, .freebsd, .netbsd, .dragonfly => struct {
            fn create() Error!std.os.fd_t {
                return std.os.kqueue() catch |err| switch (err) {
                    .ProcessFdQuotaExceeded => error.OutOfHandles,
                    .SystemFdQuotaExceeded => error.OutOfHandles,
                    else => |unexpected| unexpected,
                };
            }

            fn register(poll_fd: std.os.fd_t, fd: std.os.fd_t, data: usize) RegisterError!void {
                const event_list = &[0]std.os.Kevent{};
                var change_list: [2]std.os.Kevent = undefined;
                change_list[0] = std.os.Kevent{
                    .ident = fd,
                    .filter = std.os.EVFILT_READ,
                    .flags = std.os.EV_ADD | std.os.EV_ENABLE | std.os.EV_CLEAR,
                    .fflags = 0,
                    .data = 0,
                    .udata = data,
                };
                change_list[1] = change_list[0];
                change_list[1].filter = std.os.EVFILT_WRITE;

                _ = std.os.kevent(poll_fd, change_list[0..], event_list, null) catch |err| switch (err) {
                    .AccessDenied => error.InvalidHandle,
                    .EventNotFound => unreachable,
                    .SystemResources => error.OutOfMemory,
                    .ProcessNotFound => unreachable,
                    .Overflow => unreachable,
                    else => |unexpected| unexpected,
                };
            }

            fn poll(poll_fd: std.os.fd_t, events: []Event, timeout: u64) usize {
                const change_list = &[0]std.os.Kevent{};
                const event_list = @ptrCast([*]std.os.Kevent, events.ptr)[0..events.len];

                var ts: std.os.timespec = undefined;
                ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), @divFloor(timeout, std.time.ns_per_s));
                ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), @rem(timeout, std.time.ns_per_s));

                return std.os.kevent(poll_fd, change_list, event_list, &ts) catch unreachable;
            }
            
            const Event = extern struct {
                raw: std.os.Kevent,

                fn getData(self: Event) usize {
                    return self.raw.udata;
                }

                fn isReadable(self: Event) bool {
                    return self.raw.filter & std.os.EVFILT_READ != 0;
                }

                fn isWritable(self: Event) bool {
                    return self.raw.filter & std.os.EVFILT_WRITE != 0;
                }
            };
        },
        else => @compileError("Operating system not supported"),
    };
};
