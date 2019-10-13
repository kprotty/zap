const std = @import("std");
const builtin = @import("builtin");
const zio = @import("../../../zap.zig").zio;

const c = std.c;
const os = std.os;
const system = os.system;

pub const Handle = i32;

pub const Buffer = extern struct {
    inner: os.iovec_const,

    pub fn getBytes(self: @This()) []u8 {
        return self.inner.iov_base[0..self.inner.iov_len];
    }

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This(){
            .inner = os.iovec{
                .iov_base = bytes.ptr,
                .iov_len = bytes.len,
            },
        };
    }
};

pub const IncomingPadding = 0;
pub const SockAddr = extern struct {
    pub const Ipv4 = os.sockaddr_in;
    pub const Ipv6 = os.sockaddr_in6;

    inner: os.sockaddr,

    pub fn fromIpv4(address: u32, port: u16) @This() {
        return @This(){
            .inner = os.sockaddr{
                .in = Ipv4{
                    .addr = address,
                    .family = os.AF_INET,
                    .zero = [_]u8{0} ** 8,
                    .port = std.mem.nativeToBig(u16, port),
                },
            },
        };
    }

    pub fn fromIpv6(address: u128, port: u16, flowinfo: u32, scope: u32) @This() {
        return @This(){
            .inner = os.sockaddr{
                .in6 = Ipv6{
                    .scope_id = scope,
                    .flowinfo = flowinfo,
                    .family = os.AF_INET6,
                    .addr = @bitCast([16]u8, address),
                    .port = std.mem.nativeToBig(@typeOf(port), port),
                },
            },
        };
    }
};

pub const Event = struct {
    inner: os.Kevent,

    pub fn readData(self: @This(), poller: *Poller) usize {
        return self.inner.udata;
    }

    pub fn getToken(self: @This()) usize {
        var token: usize = 0;
        if ((self.inner.flags & (os.EV_EOF | os.EV_ERROR)) != 0)
            token |= zio.Event.Disposable;
        return token | switch (self.inner.filter) {
            os.EVFILT_WRITE => zio.Event.Writeable,
            os.EVFILT_READ => zio.Event.Readable,
            os.EVFILT_USER => 0,
            else => unreachable,
        };
    }

    pub const Poller = struct {
        kqueue: Handle,

        pub fn new() zio.Event.Poller.Error!@This() {
            const handle = c.kqueue();
            return switch (os.errno(handle)) {
                0 => @This(){ .handle = handle },
                os.EMFILE, os.ENFILE, os.ENOMEM => zio.Event.Poller.Error.OutOfResources,
                else => unreachable,
            };
        }

        pub fn close(self: *@This()) void {
            _ = c.close(self.kqueue);
        }

        pub fn getHandle(self: @This()) zio.Handle {
            return self.kqueue;
        }

        pub fn fromHandle(handle: zio.Handle) @This() {
            return @This(){ .kqueue = handle };
        }

        pub fn register(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            var num_events: usize = 0;
            var events: [2]os.Kevent = undefined;

            events[0].flags = os.EV_ADD | if ((flags & zio.Event.OneShot) != 0) os.EV_ONESHOT else os.EV_CLEAR;
            events[0].ident = @intCast(usize, handle);
            events[0].udata = data;
            events[0].fflags = 0;
            events[1] = events[0];

            if ((flags & zio.Event.Readable) != 0) {
                events[num_events].filter = os.EVFILT_READ;
                num_events += 1;
            }
            if ((flags & zio.Event.Writeable) != 0) {
                events[num_events].filter = os.EVFILT_WRITE;
                num_events += 1;
            }
            if (num_events == 0)
                return zio.Event.Poller.RegisterError.InvalidValue;
            return self.kevent(events[0..num_events], ([*]os.Kevent)(undefined)[0..0], null);
        }

        pub fn reregister(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            return self.register(handle, flags, data);
        }

        pub fn notify(self: *@This(), data: usize) zio.Event.Poller.NotifyError!void {
            var events: [1]os.Kevent = undefined;
            events[0] = os.Kevent{
                .data = 0,
                .flags = 0,
                .udata = data,
                .filter = os.EVFILT_USER,
                .fflags = os.NOTE_TRIGGER,
                .ident = @intCast(usize, self.kqueue),
            };

            return self.kevent(events[0..], ([*]os.Kevent)(undefined)[0..0], null) catch |err| switch (err) {
                .InvalidEvents => unreachable,
                else => |err| err,
            };
        }

        pub fn poll(self: *@This(), events: []Event, timeout: ?u32) zio.Event.Poller.PollError![]Event {
            const empty_set = ([*]os.Kevent)(undefined)[0..0];
            const event_set = @ptrCast([*]os.Kevent, events.ptr)[0..events.len];
            return self.kevent(empty_set, event_set, timeout);
        }

        pub fn poll(self: *@This(), events: []Event, timeout: ?u32) zio.Event.Poller.PollError![]Event {
            const timeout_ms = if (timeout) |t| @intCast(i32, t) else -1;
            const events_ptr = @ptrCast([*]linux.epoll_event, events.ptr);
            while (true) {
                const events_found = linux.epoll_wait(self.epoll_fd, events_ptr, @intCast(u32, events.len), timeout_ms);
                switch (linux.getErrno(events_found)) {
                    0 => return events[0..events_found],
                    linux.EBADF, linux.EINVAL => return zio.Event.Poller.PollError.InvalidHandle,
                    linux.EFAULT => return zio.Event.Poller.PollError.InvalidEvents,
                    linux.EINTR => continue,
                    else => unreachable,
                }
            }
        }

        fn kevent(self: *@This(), change_set: []os.Kevent, event_set: []os.Kevent, timeout: ?u32) zio.Event.Poller.PollError!usize {
            var ts: os.timespec = undefined;
            var ts_ptr: ?*os.timespec = null;
            if (timeout) |timeout_ms| {
                if (timeout_ms > 0) {
                    ts.tv_nsec = (timeout_ms % 1000) * 1000000;
                    ts.tv_sec = timeout_ms / 1000;
                    ts_ptr = &ts;
                }
            }

            while (true) {
                const events_found = os.kevent(self.kqueue, change_set.ptr, change_set.len, event_set.ptr, event_set.len, ts_ptr);
                switch (os.errno(events_found)) {
                    0 => return event_set[0..events_found],
                    os.EACCES, os.EFAULT, os.ENOENT, os.ENOMEM => return zio.Event.Poller.PollError.InvalidEvents,
                    os.ESRCH, os.EBADF => return zio.Event.Poller.PollError.InvalidHandle,
                    os.EINVAL => unreachable,
                    os.EINTR => continue,
                    else => unreachable,
                }
            }
        }
    };
};

pub const Socket = struct {
    handle: Handle,

    pub fn new(flags: zio.Socket.Flags) zio.Socket.Error!@This() {
        var domain: u32 = 0;
        if ((flags & zio.Socket.Ipv4) != 0) {
            domain = os.AF_INET;
        } else if ((flags & zio.Socket.Ipv6) != 0) {
            domain = os.AF_INET6;
        } else if (builtin.os == .linux) {
            domain = os.AF_PACKET;
        }

        var protocol: u32 = 0;
        var sock_type: u32 = 0;
        if ((flags & zio.Socket.Nonblock) != 0)
            sock_type |= os.SOCK_NONBLOCK;
        if ((flags & zio.Socket.Tcp) != 0) {
            protocol |= Options.IPPROTO_TCP;
            sock_type |= os.SOCK_STREAM;
        } else if ((flags & zio.Socket.Udp) != 0) {
            protocol |= Options.IPPROTO_UDP;
            sock_type |= os.SOCK_DGRAM;
        } else if ((flags & zio.Socket.Raw) != 0) {
            sock_type |= os.SOCK_RAW;
        }

        const handle = CreateSocket(domain, sock_type | os.SOCK_CLOEXEC, protocol);
        return switch (os.errno(handle)) {
            0 => @This(){ .handle = @intCast(zio.Handle, handle) },
            os.EINVAL, os.EAFNOSUPPORT, os.EPROTONOSUPPORT => zio.Socket.Error.InvalidValue,
            os.ENFILE, os.EMFILE, os.ENOBUFS, os.ENOMEM => zio.Socket.Error.OutOfResources,
            os.EACCES => zio.Socket.Error.InvalidState,
            else => unreachable,
        };
    }

    pub fn close(self: *@This()) void {
        _ = system.close(self.handle);
    }

    pub fn fromHandle(handle: zio.Handle, flags: zio.Socket.Flags) @This() {
        return @This(){ .handle = handle };
    }

    pub fn getHandle(self: @This()) zio.Handle {
        return self.handle;
    }

    pub const Linger = extern struct {
        l_onoff: c_int,
        l_linger: c_int,
    };

    pub fn setOption(self: *@This(), option: zio.Socket.Option) zio.Socket.OptionError!void {
        var option_ref = option;
        return switch (errno(socketOption(self.handle, &option_ref, Setsockopt, Options))) {
            0 => {},
            os.ENOPROTOOPT, os.EFAULT, os.EINVAL => zio.Socket.OptionError.InvalidValue,
            os.EBADF, os.ENOTSOCK => zio.Socket.OptionError.InvalidHandle,
            else => unreachable,
        };
    }

    pub fn getOption(self: @This(), option: *zio.Socket.Option) zio.Socket.OptionError!void {
        return switch (errno(socketOption(self.handle, option, Getsockopt, Options))) {
            0 => {},
            os.ENOPROTOOPT, os.EFAULT, os.EINVAL => zio.Socket.OptionError.InvalidValue,
            os.EBADF, os.ENOTSOCK => zio.Socket.OptionError.InvalidHandle,
            else => unreachable,
        };
    }

    const Timeval = if (builtin.os == .windows) void else os.timeval;
    pub fn socketOption(
        handle: zio.Handle,
        option: *zio.Socket.Option,
        comptime sockopt: var,
        comptime flags: type,
    ) @typeOf(sockopt).ReturnType {
        var number: c_int = undefined;
        var timeval: Timeval = undefined;
        const is_setter = @typeInfo(@typeOf(sockopt)).Fn.args[4].arg_type.? == c_int;

        var level: c_int = flags.SOL_SOCKET;
        var optname: c_int = undefined;
        var optval: usize = @ptrToInt(&number);
        var optlen: c_int = @sizeOf(@typeOf(number));

        switch (option.*) {
            .Debug => |value| {
                if (is_setter) number = if (value) 1 else 0;
                optname = flags.SO_DEBUG;
            },
            .Tcpnodelay => |value| {
                if (is_setter) number = if (value) 1 else 0;
                level = flags.IPPROTO_TCP;
                optname = flags.TCP_NODELAY;
            },
            .Linger => |value| {
                optname = flags.SO_LINGER;
                optval = @ptrToInt(&option.Linger);
                optlen = @sizeOf(@typeOf(value));
            },
            .Broadcast => |value| {
                if (is_setter) number = if (value) 1 else 0;
                optname = flags.SO_BROADCAST;
            },
            .Reuseaddr => |value| {
                if (is_setter) number = if (value) 1 else 0;
                optname = flags.SO_REUSEADDR;
            },
            .Keepalive => |value| {
                if (is_setter) number = if (value) 1 else 0;
                optname = flags.SO_KEEPALIVE;
            },
            .Oobinline => |value| {
                if (is_setter) number = if (value) 1 else 0;
                optname = flags.SO_OOBINLINE;
            },
            .SendBufMax => |value| {
                if (is_setter) number = value;
                optname = flags.SO_SNDBUF;
            },
            .RecvBufMax => |value| {
                if (is_setter) number = value;
                optname = flags.SO_RCVBUF;
            },
            .SendBufMin => |value| {
                if (is_setter) number = value;
                optname = flags.SO_SNDLOWAT;
            },
            .RecvBufMin => |value| {
                if (is_setter) number = value;
                optname = flags.SO_RCVLOWAT;
            },
            .SendTimeout => |value| {
                if (is_setter) {
                    if (builtin.os == .windows) {
                        number = value;
                    } else {
                        optval = @ptrToInt(&timeval);
                        optlen = @sizeOf(@typeOf(timeval));
                        timeval.tv_sec = @divFloor(value, 1000);
                        timeval.tv_usec = @mod(value, 1000) * 1000;
                    }
                }
                optname = flags.SO_SNDTIMEO;
            },
            .RecvTimeout => |value| {
                if (is_setter) {
                    if (builtin.os == .windows) {
                        number = value;
                    } else {
                        optval = @ptrToInt(&timeval);
                        optlen = @sizeOf(@typeOf(timeval));
                        timeval.tv_sec = @divFloor(value, 1000);
                        timeval.tv_usec = @mod(value, 1000) * 1000;
                    }
                }
                optname = flags.SO_RCVTIMEO;
            },
        }

        if (is_setter)
            return sockopt(handle, level, optname, optval, optlen);
        const result = sockopt(handle, level, optname, optval, &optlen);
        if (result == 0) {
            switch (option.*) {
                .Linger => {},
                .Debug => option.* = zio.Socket.Option{ .Debug = number != 0 },
                .Broadcast => option.* = zio.Socket.Option{ .Debug = number != 0 },
                .Reuseaddr => option.* = zio.Socket.Option{ .Reuseaddr = number != 0 },
                .Keepalive => option.* = zio.Socket.Option{ .Keepalive = number != 0 },
                .Oobinline => option.* = zio.Socket.Option{ .Oobinline = number != 0 },
                .Tcpnodelay => option.* = zio.Socket.Option{ .Tcpnodelay = number != 0 },
                .SendBufMax => option.* = zio.Socket.Option{ .SendBufMax = number },
                .RecvBufMax => option.* = zio.Socket.Option{ .RecvBufMax = number },
                .SendBufMin => option.* = zio.Socket.Option{ .SendBufMin = number },
                .RecvBufMin => option.* = zio.Socket.Option{ .RecvBufMin = number },
                .SendTimeout => {
                    if (builtin.os != .windows)
                        number = @intCast(c_int, (timeval.tv_sec * 1000) + @divFloor(timeval.tv_usec, 1000));
                    option.* = zio.Socket.Option{ .SendTimeout = number };
                },
                .RecvTimeout => {
                    if (builtin.os != .windows)
                        number = @intCast(c_int, (timeval.tv_sec * 1000) + @divFloor(timeval.tv_usec, 1000));
                    option.* = zio.Socket.Option{ .RecvTimeout = number };
                },
            }
        }
        return result;
    }

    pub fn bind(self: *@This(), address: *const zio.Address) zio.Socket.BindError!void {
        return switch (errno(Bind(self.handle, address))) {
            0 => {},
            os.EACCES, os.ELOOP, os.EFAULT, os.ENAMETOOLONG, os.EADDRNOTAVAIL => zio.Socket.BindError.InvalidAddress,
            os.EINVAL, os.ENOTSOCK, os.ENOENT, os.ENOTDIR, os.EROFS => zio.Socket.BindError.InvalidHandle,
            os.EADDRINUSE => zio.Socket.BindError.AddressInUse,
            os.ENOMEM => zio.Socket.BindError.InvalidState,
            else => unreachable,
        };
    }

    pub fn listen(self: *@This(), backlog: c_uint) zio.Socket.ListenError!void {
        return switch (errno(Listen(self.handle, backlog))) {
            0 => {},
            os.EBADF, os.ENOTSOCK, os.EOPNOTSUPP => zio.Socket.ListenError.InvalidHandle,
            os.EADDRINUSE => zio.Socket.ListenError.AddressInUse,
            else => unreachable,
        };
    }

    pub fn connect(self: *@This(), address: *const zio.Address, token: usize) zio.Socket.ConnectError!void {
        if ((token & zio.Event.Disposable) != 0)
            return zio.ErrorClosed;
        if ((token & zio.Event.Writeable) != 0) {
            var errno_value: c_int = undefined;
            var errno_len: c_int = @sizeOf(@typeOf(errno_value));
            if (Getsockopt(self.handle, Options.SOL_SOCKET, Options.SO_ERROR, @ptrToInt(&errno_value), &errno_len) != 0)
                return zio.Socket.ConnectError.InvalidHandle;
            if (errno_value == 0)
                return;
            _ = try getConnectError(@intCast(u16, -errno_value));
        } else if (token != 0) {
            return zio.ErrorInvalidToken;
        }

        while (try getConnectError(errno(Connect(self.handle, address)))) {}
    }

    fn getConnectError(errno_value: u16) zio.Socket.ConnectError!bool {
        return switch (errno_value) {
            0 => false,
            os.EFAULT, os.EAFNOSUPPORT, os.EADDRNOTAVAIL, os.EADDRINUSE => zio.Socket.ConnectError.InvalidAddress,
            os.EBADF, os.EACCES, os.ENOTSOCK, os.EPROTOTYPE => zio.Socket.ConnectError.InvalidHandle,
            os.ECONNREFUSED, os.EPERM => zio.Socket.ConnectError.Refused,
            os.EAGAIN, os.EALREADY, os.EINPROGRESS => zio.ErrorPending,
            os.ENETUNREACH => zio.Socket.ConnectError.InvalidState,
            os.EISCONN => zio.Socket.ConnectError.AlreadyConnected,
            os.ETIMEDOUT => zio.Socket.ConnectError.TimedOut,
            os.EINTR => true,
            else => unreachable,
        };
    }

    pub fn accept(self: *@This(), flags: zio.Socket.Flags, incoming: *zio.Address.Incoming, token: usize) zio.Socket.AcceptError!void {
        if ((token & zio.Event.Disposable) != 0)
            return zio.ErrorClosed;
        if (token != 0 and (token & zio.Event.Readable) == 0)
            return zio.ErrorInvalidToken;

        while (true) {
            const fd = Accept(self.handle, flags, &incoming.address);
            switch (errno(fd)) {
                0 => {
                    incoming.handle = @intCast(zio.Handle, fd);
                    return;
                },
                os.EMFILE, os.ENFILE, os.ENOBUFS, os.ENOMEM => return zio.Socket.AcceptError.OutOfResources,
                os.EBADF, os.EINVAL, os.ENOTSOCK, os.EOPNOTSUPP => return zio.Socket.AcceptError.InvalidHandle,
                os.EPERM, os.ECONNABORTED, os.EPROTO => return zio.Socket.AcceptError.Refused,
                os.EFAULT => return zio.Socket.AcceptError.InvalidAddress,
                os.EAGAIN => return zio.ErrorPending,
                os.EINTR => continue,
                else => unreachable,
            }
        }
    }

    pub fn recvmsg(self: *@This(), address: ?*zio.Address, buffers: []Buffer, token: usize) zio.Socket.DataError!usize {
        if ((token & zio.Event.Disposable) != 0)
            return zio.ErrorClosed;
        if (token != 0 and (token & zio.Event.Readable) == 0)
            return zio.ErrorInvalidToken;
        return transfer(self.handle, address, buffers, Recvmsg);
    }

    pub fn sendmsg(self: *@This(), address: ?*const zio.Address, buffers: []const Buffer, token: usize) zio.Socket.DataError!usize {
        if ((token & zio.Event.Disposable) != 0)
            return zio.ErrorClosed;
        if (token != 0 and (token & zio.Event.Writeable) == 0)
            return zio.ErrorInvalidToken;
        return transfer(self.handle, address, buffers, Sendmsg);
    }

    fn transfer(handle: zio.Handle, address: var, buffers: var, comptime Transfer: var) zio.Socket.DataError!usize {
        var message_header = msghdr{
            .msg_name = if (address) |addr| @ptrToInt(&addr.sockaddr) else 0,
            .msg_namelen = if (address) |addr| addr.length else 0,
            .msg_iov = @ptrToInt(buffers.ptr),
            .msg_iovlen = buffers.len,
            .msg_control = 0,
            .msg_controllen = 0,
            .msg_flags = 0,
        };

        while (true) {
            const transferred = Transfer(handle, &message_header, MSG_NOSIGNAL);
            switch (errno(transferred)) {
                0 => return transferred,
                os.EOPNOTSUPP, os.EINVAL, os.EFAULT, os.EISCONN, os.ENOTCONN => return zio.Socket.DataError.InvalidValue,
                os.EACCES, os.EBADF, os.EDESTADDRREQ, os.ENOTSOCK => return zio.Socket.DataError.InvalidHandle,
                os.ENOMEM, os.ENOBUFS => return zio.Socket.DataError.OutOfResources,
                os.EPIPE, os.ECONNRESET => return zio.ErrorClosed,
                os.EAGAIN => return zio.ErrorPending,
                os.EMSGSIZE => unreachable,
                os.EINTR => continue,
                else => unreachable,
            }
        }
    }
};

const Options = struct {
    pub const IPPROTO_TCP = 6;
    pub const IPPROTO_UDP = 17;
    pub const TCP_NODELAY = 1;
    pub const SOL_SOCKET = os.SOL_SOCKET;
    pub const SO_ERROR = os.SO_ERROR;
    pub const SO_DEBUG = os.SO_DEBUG;
    pub const SO_LINGER = os.SO_LINGER;
    pub const SO_BROADCAST = os.SO_BROADCAST;
    pub const SO_REUSEADDR = os.SO_REUSEADDR;
    pub const SO_KEEPALIVE = os.SO_KEEPALIVE;
    pub const SO_OOBINLINE = os.SO_OOBINLINE;
    pub const SO_RCVBUF = os.SO_RCVBUF;
    pub const SO_RCVLOWAT = os.SO_RCVLOWAT;
    pub const SO_RCVTIMEO = os.SO_RCVTIMEO;
    pub const SO_SNDBUF = os.SO_SNDBUF;
    pub const SO_SNDLOWAT = os.SO_SNDLOWAT;
    pub const SO_SNDTIMEO = os.SO_SNDTIMEO;
};

const MSG_NOSIGNAL = 0x4000;
const msghdr = extern struct {
    msg_name: usize,
    msg_namelen: c_uint,
    msg_iov: usize,
    msg_iovlen: usize,
    msg_control: usize,
    msg_controllen: usize,
    msg_flags: c_uint,
};

const C = struct {
    pub extern "c" fn getsockopt(fd: i32, level: c_int, optname: c_int, optval: usize, optlen: *c_int) usize;
    pub extern "c" fn setsockopt(fd: i32, level: c_int, optname: c_int, optval: usize, optlen: c_int) usize;
    pub extern "c" fn accept4(fd: i32, addr: *os.sockaddr, len: *c_uint, flags: c_uint) usize;
    pub extern "c" fn connect(fd: i32, addr: *const os.sockaddr, len: c_int) usize;
    pub extern "c" fn bind(fd: i32, addr: *const os.sockaddr, len: c_uint) usize;
    pub extern "c" fn socket(domain: u32, sock_type: u32, protocol: u32) usize;
    pub extern "c" fn sendmsg(fd: i32, msg: *const msghdr, flags: c_int) usize;
    pub extern "c" fn recvmsg(fd: i32, msg: *msghdr, flags: c_int) usize;
    pub extern "c" fn listen(fd: i32, backlog: c_uint) usize;
};

inline fn errno(value: usize) u16 {
    if (builtin.os != .linux)
        return os.errno(@bitCast(isize, value));
    return os.errno(value);
}

inline fn CreateSocket(domain: u32, sock_type: u32, protocol: u32) usize {
    if (builtin.os != .linux)
        return C.socket(domain, sock_type, protocol);
    return system.syscall3(
        system.SYS_socket,
        @intCast(usize, domain),
        @intCast(usize, sock_type),
        @intCast(usize, protocol),
    );
}

inline fn Getsockopt(fd: zio.Handle, level: c_int, optname: c_int, optval: usize, optlen: *c_int) usize {
    if (builtin.os != .linux)
        return C.setsockopt(fd, level, optname, optval, optlen);
    return system.syscall5(
        system.SYS_getsockopt,
        @intCast(usize, fd),
        @intCast(usize, level),
        @intCast(usize, optname),
        optval,
        @ptrToInt(optlen),
    );
}

inline fn Setsockopt(fd: zio.Handle, level: c_int, optname: c_int, optval: usize, optlen: c_int) usize {
    if (builtin.os != .linux)
        return C.setsockopt(fd, level, optname, optval, optlen);
    return system.syscall5(
        system.SYS_setsockopt,
        @intCast(usize, fd),
        @intCast(usize, level),
        @intCast(usize, optname),
        optval,
        @intCast(usize, optlen),
    );
}

inline fn Accept(fd: zio.Handle, socket_flags: zio.Socket.Flags, address: *zio.Address) usize {
    var flags: c_uint = os.SOCK_CLOEXEC;
    if ((socket_flags & zio.Socket.Nonblock) != 0)
        flags |= os.SOCK_NONBLOCK;

    if (builtin.os != .linux)
        return C.accept4(fd, @ptrCast(*os.sockaddr, &address.sockaddr), &address.length, flags);
    return system.syscall4(
        system.SYS_accept4,
        @intCast(usize, fd),
        @ptrToInt(&address.sockaddr),
        @ptrToInt(&address.length),
        @intCast(usize, flags),
    );
}

inline fn Connect(fd: zio.Handle, address: *const zio.Address) usize {
    if (builtin.os != .linux)
        return C.connect(fd, @ptrCast(*const os.sockaddr, &address.sockaddr), address.length);
    return system.syscall3(
        system.SYS_connect,
        @intCast(usize, fd),
        @ptrToInt(&address.sockaddr),
        @intCast(usize, address.length),
    );
}

inline fn Sendmsg(fd: zio.Handle, message_header: *const msghdr, flags: c_int) usize {
    if (builtin.os != .linux)
        return C.recvmsg(fd, message_header, flags);
    return system.syscall3(
        system.SYS_sendmsg,
        @intCast(usize, fd),
        @ptrToInt(message_header),
        @intCast(usize, flags),
    );
}

inline fn Recvmsg(fd: zio.Handle, message_header: *msghdr, flags: c_int) usize {
    if (builtin.os != .linux)
        return C.recvmsg(fd, message_header, flags);
    return system.syscall3(
        system.SYS_recvmsg,
        @intCast(usize, fd),
        @ptrToInt(message_header),
        @intCast(usize, flags),
    );
}

inline fn Bind(fd: zio.Handle, address: *const zio.Address) usize {
    if (builtin.os != .linux)
        return C.bind(fd, @ptrCast(*const os.sockaddr, &address.sockaddr), address.length);
    return system.syscall3(
        system.SYS_bind,
        @intCast(usize, fd),
        @ptrToInt(&address.sockaddr),
        @intCast(usize, address.length),
    );
}

inline fn Listen(fd: zio.Handle, backlog: c_uint) usize {
    if (builtin.os != .linux)
        return C.listen(fd, backlog);
    return system.syscall2(
        system.SYS_listen,
        @intCast(usize, fd),
        @intCast(usize, backlog),
    );
}
