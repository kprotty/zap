const std = @import("std");
const builtin = @import("builtin");
const zio = @import("../../zio.zig");

const os = std.os;
const system = os.system;

/// Needs to possibly return an error for the return type :/
var dummy_var: u8 = 0;
pub fn initialize() zio.InitError!void {
    if (@ptrCast(*volatile u8, &dummy_var).* != 0)
        return zio.InitError.InvalidState;
}

pub fn cleanup() void {
    // nothing to clean up
}

pub const Handle = i32;

pub const Buffer = struct {
    inner: os.iovec_const,

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This() {
            .inner = os.iovec_const {
                .iov_base = bytes.ptr,
                .iov_len = bytes.len,
            }
        };
    }

    pub fn getBytes(self: @This()) []u8 {
        return self.inner.iov_base[0..self.inner.iov_len];
    }
};

pub const Ipv4 = packed struct {
    inner: os.sockaddr_in,

    pub fn from(address: u32, port: u16) @This() {
        return @This() {
            .inner = os.sockaddr_in {
                .sin_family = os.AF_INET,
                .sin_port = std.mem.nativeToBig(@typeOf(port), port),
                .sin_zero = [_]u8{0} * @sizeOf(@typeOf(os.sockaddr_in(undefined).sin_zero)),
                .sin_addr = os.in_addr { .s_addr = std.mem.nativeToBig(@typeOf(address), address) },
            }
        };
    }
};

pub const Ipv6 = packed struct {
    inner: os.sockaddr_in6,

    pub fn from(address: u128, port: u16, flow: u32, scope: u32) @This() {
        return @This() {
            .inner = os.sockaddr_in6 {
                .sin6_family = os.AF_INET6,
                .sin6_port = std.mem.nativeToBig(@typeOf(port), port),
                .sin6_flowinfo = std.mem.nativeToBig(@typeOf(flow), flow),
                .sin6_scope_id = std.mem.nativeToBig(@typeOf(scope), scope),
                .sin6_addr = os.in_addr6 { .Qword = std.mem.nativeToBig(@typeOf(address), address) },
            }
        };
    }
};

pub const Incoming = struct {
    handle: zio.Handle,
    address: zio.Address,

    pub fn from(address: zio.Address) @This() {
        return @This() { .handle = undefined, .address = address };    
    }

    pub fn getSocket(self: @This()) Socket {
        return Socket.fromHandle(self.handle);
    }

    pub fn getAddress(self: @This()) zio.Address {
        return self.addres;
    }
};

pub const Event = struct {
    inner: os.Kevent,

    pub fn getData(self: *@This(), poller: *Poller) usize {
        return self.inner.udata;
    }

    pub fn getResult(self: *@This()) zio.Result {
        return zio.Result {
            .data = self.inner.data,
            .status = switch (self.inner.flags & (os.EV_EOF | os.EV_ERROR)) {
                0 => .Retry,
                else => .Error,
            }
        };
    }

    pub const Poller = struct {
        kqueue: Handle,

        pub fn init(self: *@This()) zio.Event.Poller.InitError!void {
            const kqueue = os.kqueue();
            return switch (os.errno(kqueue)) {
                0 => self.kqueue = @intCast(Handle, kqueue),
                os.ENOMEM => zio.Event.Poller.InitError.OutOfResources,
                else => unreachable,
            };
        }

        pub fn close(self: *@This()) void {
            _ = os.close(self.kqueue);
        }

        pub fn getHandle(self: @This()) zio.Handle {
            return self.kqueue;
        }

        pub fn fromHandle(handle: zio.Handle) @This() {
            return @This() { .kqueue = handle };
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

        pub fn send(self: *@This(), data: usize) zio.Event.Poller.SendError!void {
            var events: [1]os.Kevent = undefined;
            events[0] = os.Kevent {
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

        fn kevent(self: *@This(), change_set: []os.Kevent, event_set: []os.Kevent, timeout: ?u32) zio.Event.Poller.PollError!usize {
            var ts: os.timespec = undefined;
            var ts_ptr: ?*os.timespec = null;
            if (timeout) |timeout_ms| {
                ts.tv_nsec = (timeout_ms % 1000) * 1000000;
                ts.tv_sec = timeout_ms / 1000;
                ts_ptr = &ts;
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
    flags: u8,
    
    pub fn init(self: *@This(), flags: u8) zio.Socket.InitError!void {
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
        if ((flags & zio.Socket.Nonblock))
            sock_type = os.SOCK_NONBLOCK;
        if ((flags & zio.Socket.Tcp) != 0) {
            protocol = os.IPPROTO_TCP;
            sock_type = os.SOCK_STREAM;
        } else if ((flags & zio.Socket.Udp) != 0) {
            protocol = os.IPPROTO_UDP;
            sock_type = os.SOCK_DGRAM;
        } else if ((flags & zio.Socket.Raw) != 0) {
            sock_type = os.SOCK_RAW;
        }
        
        self.flags = flags;
        const handle = os.socket(domain, sock_type | os.SOCK_CLOEXEC, protocol);
        return switch (os.errno(handle)) {
            0 => self.handle = @intCast(Handle, handle),
            os.ENFILE, os.EMFILE, os.ENOBUFS, os.ENOMEM => zio.Socket.InitError.OutOfResources,
            os.EINVAL, os.EAFNOSUPPORT, os.EPROTONOSUPPORT => zio.Socket.InitError.InvalidValue,
            os.EACCES => zio.Socket.InitError.InvalidState,
            else => unreachable,
        };
    }

    pub fn close(self: *@This()) void {
        _ = os.close(self.handle);
    }

    pub fn getHandle(self: @This()) zio.Handle {
        return self.handle;
    }

    pub fn fromHandle(handle: zio.Handle, flags: u8) @This() {
        return @This() { .handle = handle, .flags = flags };
    }

    pub fn isReadable(self: *const @This(), event: Event) bool {
        if (builtin.os == .linux)
            return (event.inner.events & os.EPOLLIN) != 0;
        return event.inner.filter == os.EVFILT_READ;
    }

    pub fn isWriteable(self: *const @This(), event: Event) bool {
        if (builtin.os == .linux)
            return (event.inner.events & os.EPOLLOUT) != 0;
        return event.inner.filter == os.EVFILT_WRITE;
    }

    pub fn setOption(self: *@This(), option: zio.Option) zio.Socket.OptionError!void {
        var option_val = option;
        return switch os.errno(socketOption(true, self.handle, &option_val, Setsockopt, os)) {

        };
    }

    pub fn getOption(self: *@This(), option: *zio.Option) zio.Socket.OptionError!void {
        return switch os.errno(socketOption(false, self.handle, &option_val, Getsockopt, os)) {

        };
    }

    pub const Linger = extern struct {
        l_onoff: c_int,
        l_linger: c_int,
    };

    pub fn socketOption(comptime set: bool, handle: zio.Handle, option: *zio.Option, comptime apply: var, comptime options: var) c_int {
        var number: c_int = undefined;
        var level: c_int = options.SOL_SOCKET;
        var opt_name: c_int = undefined;
        var opt_val: usize = @ptrToInt(number);
        var opt_len: c_int = @sizeOf(@typeOf(number));

        switch (option.*) {
            .Debug => |value| {
                if (set) number = if (value) 1 else 0;
                opt_name = options.SO_DEBUG;
            },
            .Tcpnodelay => |value| {
                if (set) number = if (value) 1 else 0;
                level = options.IPPROTO_TCP;
                opt_name = options.TCP_NODELAY;
            },
            .Linger => |value| {
                opt_name = options.SO_LINGER;
                opt_val = @ptrToInt(&option.Linger);
                opt_len = @sizeOf(@typeOf(value));
            },
            .Broadcast => |value| {
                if (set) number = if (value) 1 else 0;
                opt_name = options.SO_BROADCAST;
            },
            .Reuseaddr => |value| {
                if (set) number = if (value) 1 else 0;
                opt_name = options.SO_REUSEADDR;
            },
            .Keepalive => |value| {
                if (set) number = if (value) 1 else 0;
                opt_name = options.SO_KEEPALIVE;
            },
            .Oobinline => |value| {
                if (set) number = if (value) 1 else 0;
                opt_name = options.SO_OOBLINE;
            },
            .RecvBufMax => |value| {
                if (set) number = value;
                opt_name = options.SO_RCVBUF;
            },
            .RecvBufMin => |value| {
                if (set) number = value;
                opt_name = options.SO_RCVLOWAT;
            },
            .RecvTimeout => |value| {
                if (set) number = value;
                opt_name = options.SO_RCVTIMEO;
            },
            .SendBufMax => |value| {
                if (set) number = value;
                opt_name = options.SO_SNDBUF;
            },
            .SendBufMin => |value| {
                if (set) number = value;
                opt_name = options.SO_SNDLOWAT;
            },
            .SendTimeout => |value| {
                if (set) number = value;
                opt_name = options.SO_SNDTIMEO;
            },
        }

        if (set) return apply(self.handle, level, opt_name, opt_val, opt_len);
        const result = apply(self.handle, level, opt_name, opt_val, &opt_len);
        if (result == 0) {
            switch (option.*) {
                .Linger => {},
                .Debug => option.* = zio.Option { .Debug = number != 0 },
                .Broadcast => option.* = zio.Option { .Debug = number != 0 },
                .Reuseaddr => option.* = zio.Option { .Reuseaddr = number != 0 },
                .Keepalive => option.* = zio.Option { .Keepalive = number != 0 },
                .Oobinline => option.* = zio.Option { .Oobinline = number != 0 },
                .Tcpnodelay => option.* = zio.Option { .Tcpnodelay = number != 0 },
                .RecvBufMax => option.* = zio.Option { .RecvBufMax = number },
                .RecvBufMin => option.* = zio.Option { .RecvBufMin = number },
                .RecvTimeout => option.* = zio.Option { .RecvTimeout = number },
                .SendBufMax => option.* = zio.Option { .SendBufMax = number },
                .SendBufMin => option.* = zio.Option { .SendBufMin = number },
                .SendTimeout => option.* = zio.Option { .SendTimeout = number },
            }
        }
        return result;
    }

    pub fn bind(self: *@This(), address: *const zio.Address) zio.Socket.BindError!void {
        const address_len = @intCast(c_int, address.len);
        const address_ptr = @ptrCast(*const os.sockaddr, &address.ip);
        return switch (os.errno(system.bind(self.handle, address_ptr, address_len))) {
            0 => {},
            os.ELOOP, os.EBADF, os.EFAULT, os.ENAMETOOLONG, os.ENOENT, os.ENOTDIR => zio.Socket.BindError.InvalidValue,
            os.EACCES, os.ENOMEM, o.EROFS => zio.Socket.BindError.InvalidState,
            os.EADDRINUSE, os.EINVAL => zio.Socket.BindError.AddressInUse,
            else => unreachable,
        };
    }

    pub fn listen(self: *@This(), backlog: u16) zio.Socket.ListenError!void {
        return switch (os.errno(system.listen(self.handle, backlog))) {
            0 => {},
            os.EOPNOTSUPP => zio.Socket.ListenError.InvalidState,
            os.EADDRINUSE => zio.Socket.ListenError.AddressInUse,
            os.EBADF => zio.Socket.ListenError.InvalidValue,
            else => unreachable,
        };
    }

    pub fn connect(self: *@This(), address: *const zio.Address) zio.Result {
        while (true) {
            const result = Connect(self.handle, @ptrCast(*const os.sockaddr, &address.ip), @intCast(c_int, address.len));
            switch (os.errno(result)) {
                os.EINTR => continue,
                0 => return zio.Result { .status = .Completed, .data = 0 },
                os.EAGAIN, os.EWOULDBLOCK, os.EINPROGRESS => 
                    return zio.Result { .status = .Retry, .data = 0 },
                os.EACCES, os.EPERM, os.EADDRINUSE, os.EADDRNOTAVAIL, os.EAFNOSUPPORT, os.EALREADY, os.EBADF,
                os.ECONNREFUSED, os.EFAULT, os.ISCONN, os.ENETUNREACH, os.ENOTSOCK, os.EPROTOTYPE, os.ETIMEDOUT =>
                    return zio.Result { .status = .Error, .data = 0 },
                else => unreachable,
            }
        }
    }

    pub fn accept(self: *@This(), incoming: *zio.Address.Incoming) zio.Result {
        while (true) {
            const fd = Accept(self.handle, @ptrCast(*os.sockaddr, &incoming.address), @intCast(c_int, incoming.address.len), self.flags);
            incoming.handle = @intCast(zio.Handle, fd);
            switch (os.errno(fd)) {
                os.EINTR => continue,
                0 => return zio.Result { .status = .Completed, .data = 0 },
                os.EAGAIN, os.EWOULDBLOCK =>
                    return zio.Result { .status = .Retry, .data = 0 },
                os.EBADF, os.ECONNABORTED, os.EFAULT, os.EINVAL, os.EMFILE,
                os.ENOBUFS, os.ENOMEM, os.ENOTSOCK, os.EOPNOTSUPP, os.EPROTO, os.EPERM,
                os.ENOSR, os.ESOCKTNOSUPPORT, os.EPROTONOSUPPORT, os.ETIMEDOUT, os.ERESTARTSYS =>
                    return zio.Result { .status = .Error, .data = 0 },
                else => unreachable,
            }
        }
    }

    pub fn recv(self: *@This(), address: ?*zio.Address, buffers: []zio.Buffer) zio.Result {
        return self.performIO(address, buffers, Recvmsg);
    }

    pub fn send(self: *@This(), address: ?*const zio.Address, buffers: []const zio.Buffer) zio.Result {
        return self.performIO(address, buffers, Sendmsg);
    }

    fn performIO(self: *@This(), address: ?*const zio.Address, buffers: []const zio.Buffer, perform: var) zio.Result {
        if (buffer.len == 0)
            return zio.Result { .status = .Completed, .data = 0 }; 

        while (true) { 
            var message_header = msghdr {
                .msg_name = @ptrToInt(address),
                .msg_namelen = if (address) |addr| @intCast(c_uint, addr.len) else 0,
                .msg_iov = @ptrCast(*const os.iovec_const, buffers.ptr),
                .msg_iovlen = @intCast(c_uint, buffers.len),
                .msg_control = 0,
                .msg_controllen = 0,
                .msg_flags = 0,
            };

            const flags = if ((self.flags & zio.Socket.Nonblock) != 0) MSG_DONTWAIT else MSG_WAITALL;
            const bytes = perform(self.handle, &message_header, flags);
            if (bytes > 0 and (message_header.msg_flags & MSG_ERRQUEUE) == 0)
                return zio.Result { .status = .Completed, .data = @intCast(u32, bytes) };

            switch (os.errno(bytes)) {
                0 => unreachable,
                os.EINTR => continue,
                os.EAGAIN, os.EWOULDBLOCK => return zio.Result { .status = .Retry, .data = 0 },
                os.EBADF, os.EINVAL, os.ENOMEM, os.ENOTCONN, os.ENOTSOCK => return zio.Result { .status = .Error, .data = 0 },
                else => unreachable,
            }
        }
    }

    const MSG_WAITALL = 0x0100;
    const MSG_DONTWAIT = 0x0040;
    const MSG_ERRQUEUE = 0x2000;
    const msghdr = extern struct {
        msg_name: usize,
        msg_namelen: c_uint,
        msg_iov: *const os.iovec_const,
        msg_iovlen: c_uint,
        msg_control: usize,
        msg_controllen: c_uint,
        msg_flags: c_uint,
    };

    extern "c" fn recvmsg(socket: Handle, message: *msghdr, flags: c_int) isize;
    fn Recvmsg(socket: Handle, message: *msghdr, flags: c_int) isize {
        if (builtin.os == .linux)
            return @intCast(isize, system.syscall3(
                system.SYS_recvmsg,
                @intCast(usize, socket),
                @ptrToInt(message),
                @intCast(c_int, flags),
            ));
        return recvmsg(socket, message, flags);
    }

    extern "c" fn sendmsg(socket: Handle, message: *const msghdr, flags: c_int) isize;
    fn Sendmsg(socket: Handle, message: *const msghdr, flags: c_int) isize {
        if (builtin.os == .linux)
            return @intCast(isize, system.syscall3(
                system.SYS_sendmsg,
                @intCast(usize, socket),
                @ptrToInt(message),
                @intCast(c_int, flags),
            ));
        return sendmsg(socket, message, flags);
    }

    extern "c" fn connect(socket: Handle, address: *const os.sockaddr, len: c_int) isize;
    fn Connect(socket: Handle, address: *const os.sockaddr, length: c_int) isize {
        if (builtin.os == .linux)
            return @intCast(isize, system.syscall3(
                system.SYS_connect,
                @intCast(usize, socket),
                @ptrToInt(address),
                @intCast(usize, length),
            ));
        return connect(socket, address, length);
    }

    extern "c" fn accept(socket: Handle, address: *os.sockaddr, len: c_int) isize;
    fn Accept(socket: Handle, address: *os.sockaddr, length: c_int, flags: u8) isize {
        if (builtin.os == .linux)
            return @intCast(isize, system.syscall4(
                system.SYS_accept4,
                @intCast(usize, socket),
                @ptrToInt(address),
                @intCast(usize, length),
                if ((flags & zio.Socket.Nonblock) != 0) os.SOCK_NONBLOCK else 0,
            ));
        return accept(socket, address, length);
    }

    extern "c" fn setsockopt(socket: Handle, level: c_int, optname: c_int, optval: usize, optlen: c_int) c_int;
    fn Setsockopt(socket: Handle, level: c_int, optname: c_int, optval: usize, optlen: c_int) c_int {
        if (builtin.os == .linux)
            return @intCast(c_int, system.syscall5(
                system.SYS_setsockopt,
                @intCast(usize, socket),
                @intCast(usize, level),
                @intCast(usize, optname),
                optval,
                @intCast(usize, optlen),
            ));
        return setsockopt(socket, level, optname, optval, optlen);
    }

    extern "c" fn getsockopt(socket: Handle, level: c_int, optname: c_int, optval: usize, optlen: *c_int) c_int;
    fn Getsockopt(socket: Handle, level: c_int, optname: c_int, optval: usize, optlen: *c_int) c_int {
        if (builtin.os == .linux)
            return @intCast(c_int, system.syscall5(
                system.SYS_getsockopt,
                @intCast(usize, socket),
                @intCast(usize, level),
                @intCast(usize, optname),
                optval,
                @ptrToInt(optlen),
            ));
        return getsockopt(socket, level, optname, optval, optlen);
    }
};