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

pub const Incoming = struct {
    handle: zio.Handle,
    address: zio.Address,
    flags: u8,

    pub fn from(address: zio.Address) @This() {
        var self: @This() = undefined;
        self.address = address;
        return self;  
    }

    pub fn getSocket(self: *@This()) Socket {
        return Socket.fromHandle(self.handle, self.flags);
    }

    pub fn getAddress(self: *@This()) zio.Address {
        return self.address;
    }
};

pub const Ipv4 = struct {
    inner: os.sockaddr_in,

    pub fn from(address: u32, port: u16) @This() {
        return @This() {
            .inner = os.sockaddr_in {
                .addr = address,
                .family = os.AF_INET,
                .zero = [_]u8{0} ** 8,
                .port = std.mem.nativeToBig(u16, port),
            }
        };
    }
};

pub const Ipv6 = struct {
    inner: os.sockaddr_in6,

    pub fn from(address: u128, port: u16, flow: u32, scope: u32) @This() {
        return @This() {
            .inner = os.sockaddr_in6 {
                .flowinfo = flow,
                .scope_id = scope,
                .family = os.AF_INET6,
                .addr = @bitCast([16]u8, address),
                .port = std.mem.nativeToBig(@typeOf(port), port),
            }
        };
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
        if ((flags & zio.Socket.Nonblock) != 0)
            sock_type = os.SOCK_NONBLOCK;
        if ((flags & zio.Socket.Tcp) != 0) {
            protocol = Options.IPPROTO_TCP;
            sock_type = os.SOCK_STREAM;
        } else if ((flags & zio.Socket.Udp) != 0) {
            protocol = Options.IPPROTO_UDP;
            sock_type = os.SOCK_DGRAM;
        } else if ((flags & zio.Socket.Raw) != 0) {
            sock_type = os.SOCK_RAW;
        }
        
        self.flags = flags;
        const handle = SOCKET(domain, sock_type | os.SOCK_CLOEXEC, protocol);
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
        return event.inner.filter == system.EVFILT_READ;
    }

    pub fn isWriteable(self: *const @This(), event: Event) bool {
        if (builtin.os == .linux)
            return (event.inner.events & system.EPOLLOUT) != 0;
        return event.inner.filter == system.EVFILT_WRITE;
    }

    pub const Linger = extern struct {
        l_onoff: c_int,
        l_linger: c_int,
    };

    pub fn setOption(self: *@This(), option: zio.Socket.Option) zio.Socket.OptionError!void {
        var option_val = option;
        return switch (os.errno(socketOption(true, self.handle, &option_val, SETSOCKOPT, Options))) {
            0 => {},
            os.ENOPROTOOPT, os.EFAULT, os.EINVAL => zio.Socket.OptionError.InvalidValue,
            os.EBADF, os.ENOTSOCK => zio.Socket.OptionError.InvalidHandle,
            else => unreachable,
        };
    }

    pub fn getOption(self: *@This(), option: *zio.Socket.Option) zio.Socket.OptionError!void {
        return switch (os.errno(socketOption(false, self.handle, option, GETSOCKOPT, Options))) {
            0 => {},
            os.ENOPROTOOPT, os.EFAULT, os.EINVAL => zio.Socket.OptionError.InvalidValue,
            os.EBADF, os.ENOTSOCK => zio.Socket.OptionError.InvalidHandle,
            else => unreachable,
        };
    }

    pub fn socketOption(
        comptime setter: bool,
        handle: zio.Handle,
        option: *zio.Socket.Option,
        comptime apply: var,
        comptime options: var,
    ) @typeOf(apply).ReturnType {
        var number: c_int = undefined;
        var level: c_int = options.SOL_SOCKET;
        var opt_name: c_int = undefined;
        var opt_val: usize = @ptrToInt(&number);
        var opt_len: c_int = @sizeOf(@typeOf(number));

        switch (option.*) {
            .Debug => |value| {
                if (setter) number = if (value) 1 else 0;
                opt_name = options.SO_DEBUG;
            },
            .Tcpnodelay => |value| {
                if (setter) number = if (value) 1 else 0;
                level = options.IPPROTO_TCP;
                opt_name = options.TCP_NODELAY;
            },
            .Linger => |value| {
                opt_name = options.SO_LINGER;
                opt_val = @ptrToInt(&option.Linger);
                opt_len = @sizeOf(@typeOf(value));
            },
            .Broadcast => |value| {
                if (setter) number = if (value) 1 else 0;
                opt_name = options.SO_BROADCAST;
            },
            .Reuseaddr => |value| {
                if (setter) number = if (value) 1 else 0;
                opt_name = options.SO_REUSEADDR;
            },
            .Keepalive => |value| {
                if (setter) number = if (value) 1 else 0;
                opt_name = options.SO_KEEPALIVE;
            },
            .Oobinline => |value| {
                if (setter) number = if (value) 1 else 0;
                opt_name = options.SO_OOBINLINE;
            },
            .RecvBufMax => |value| {
                if (setter) number = value;
                opt_name = options.SO_RCVBUF;
            },
            .RecvBufMin => |value| {
                if (setter) number = value;
                opt_name = options.SO_RCVLOWAT;
            },
            .RecvTimeout => |value| {
                if (setter) number = value;
                opt_name = options.SO_RCVTIMEO;
            },
            .SendBufMax => |value| {
                if (setter) number = value;
                opt_name = options.SO_SNDBUF;
            },
            .SendBufMin => |value| {
                if (setter) number = value;
                opt_name = options.SO_SNDLOWAT;
            },
            .SendTimeout => |value| {
                if (setter) number = value;
                opt_name = options.SO_SNDTIMEO;
            },
        }

        if (setter)
            return apply(handle, level, opt_name, opt_val, opt_len);
        const result = apply(handle, level, opt_name, opt_val, &opt_len);
        if (result == 0) {
            switch (option.*) {
                .Linger => {},
                .Debug => option.* = zio.Socket.Option { .Debug = number != 0 },
                .Broadcast => option.* = zio.Socket.Option { .Debug = number != 0 },
                .Reuseaddr => option.* = zio.Socket.Option { .Reuseaddr = number != 0 },
                .Keepalive => option.* = zio.Socket.Option { .Keepalive = number != 0 },
                .Oobinline => option.* = zio.Socket.Option { .Oobinline = number != 0 },
                .Tcpnodelay => option.* = zio.Socket.Option { .Tcpnodelay = number != 0 },
                .RecvBufMax => option.* = zio.Socket.Option { .RecvBufMax = number },
                .RecvBufMin => option.* = zio.Socket.Option { .RecvBufMin = number },
                .RecvTimeout => option.* = zio.Socket.Option { .RecvTimeout = number },
                .SendBufMax => option.* = zio.Socket.Option { .SendBufMax = number },
                .SendBufMin => option.* = zio.Socket.Option { .SendBufMin = number },
                .SendTimeout => option.* = zio.Socket.Option { .SendTimeout = number },
            }
        }
        return result;
    }

    pub fn bind(self: *@This(), address: *const zio.Address) zio.Socket.BindError!void {
        return switch (os.errno(BIND(self.handle, address))) {
            0 => {},
            os.ELOOP, os.EBADF, os.EFAULT, os.ENAMETOOLONG, os.ENOENT, os.ENOTDIR => zio.Socket.BindError.InvalidValue,
            os.EACCES, os.ENOMEM, os.EROFS => zio.Socket.BindError.InvalidState,
            os.EADDRINUSE, os.EINVAL => zio.Socket.BindError.AddressInUse,
            else => unreachable,
        };
    }

    pub fn listen(self: *@This(), backlog: u16) zio.Socket.ListenError!void {
        return switch (os.errno(LISTEN(self.handle, backlog))) {
            0 => {},
            os.EOPNOTSUPP => zio.Socket.ListenError.InvalidState,
            os.EADDRINUSE => zio.Socket.ListenError.AddressInUse,
            os.EBADF => zio.Socket.ListenError.InvalidValue,
            else => unreachable,
        };
    }

    pub fn connect(self: *@This(), address: *const zio.Address) zio.Result {
        while (true) {
            switch (os.errno(CONNECT(self.handle, address))) {
                os.EINTR => continue,
                0 => return zio.Result { .status = .Completed, .data = 0 },
                os.EAGAIN, os.EINPROGRESS => return zio.Result { .status = .Retry, .data = 0 },
                os.EACCES, os.EPERM, os.EADDRINUSE, os.EADDRNOTAVAIL, os.EAFNOSUPPORT, os.EALREADY, os.EBADF,
                os.ECONNREFUSED, os.EFAULT, os.EISCONN, os.ENETUNREACH, os.ENOTSOCK, os.EPROTOTYPE, os.ETIMEDOUT =>
                    return zio.Result { .status = .Error, .data = 0 },
                else => unreachable,
            }
        }
    }

    pub fn accept(self: *@This(), incoming: *Incoming) zio.Result {
        var sock_flags: usize = os.SOCK_CLOEXEC;
        if ((self.flags & zio.Socket.Nonblock) != 0)
            sock_flags |= os.SOCK_NONBLOCK;

        while (true) {
            const fd = ACCEPT(self.handle, &incoming.address, 0);
            incoming.handle = @intCast(zio.Handle, fd);
            incoming.flags = self.flags;
            switch (os.errno(fd)) {
                os.EINTR => continue,
                0 => return zio.Result { .status = .Completed, .data = 0 },
                os.EAGAIN => return zio.Result { .status = .Retry, .data = 0 },
                os.EBADF, os.ECONNABORTED, os.EFAULT, os.EINVAL, os.EMFILE,
                os.ENOBUFS, os.ENOMEM, os.ENOTSOCK, os.EOPNOTSUPP, os.EPROTO, 
                os.ENOSR, os.ESOCKTNOSUPPORT, os.EPROTONOSUPPORT, os.ETIMEDOUT, os.EPERM =>
                    return zio.Result { .status = .Error, .data = 0 },
                else => unreachable,
            }
        }
    }

    pub fn recv(self: *@This(), address: ?*zio.Address, buffers: []Buffer) zio.Result {
        return self.performIO(address, buffers, READV);
    }

    pub fn send(self: *@This(), address: ?*const zio.Address, buffers: []const Buffer) zio.Result {
        return self.performIO(address, buffers, WRITEV);
    }

    fn performIO(self: *@This(), address: var, buffers: var, perform: var) zio.Result {
        if (buffers.len == 0)
            return zio.Result { .status = .Completed, .data = 0 }; 

        while (true) {
            const bytes = perform(self.handle, buffers);
            switch (os.errno(bytes)) {
                0 => {
                    if (bytes > 0)
                        return zio.Result { .status = .Completed, .data = @intCast(u32, bytes) };
                    return zio.Result { .status = .Error, .data = 0 };
                },
                os.EINTR => continue,
                os.EAGAIN => return zio.Result { .status = .Retry, .data = 0 },
                os.EBADF, os.EFAULT, os.EINVAL, os.EIO, os.EISDIR => 
                    return zio.Result { .status = .Error, .data = 0 },
                else => unreachable,
            }
        }
    }
};

///-----------------------------------------------------------------------------///
///                                API Definitions                              ///
///-----------------------------------------------------------------------------///

const Options = struct {
    pub const IPPROTO_TCP: c_int = 6;
    pub const IPPROTO_UDP: c_int = 17;
    pub const TCP_NODELAY: c_int = 1;
    pub const SOL_SOCKET: c_int = os.SOL_SOCKET;
    pub const SO_DEBUG: c_int = os.SO_DEBUG;
    pub const SO_LINGER: c_int = os.SO_LINGER;
    pub const SO_BROADCAST: c_int = os.SO_BROADCAST;
    pub const SO_REUSEADDR: c_int = os.SO_REUSEADDR;
    pub const SO_KEEPALIVE: c_int = os.SO_KEEPALIVE;
    pub const SO_OOBINLINE: c_int = os.SO_OOBINLINE;
    pub const SO_RCVBUF: c_int = os.SO_RCVBUF;
    pub const SO_RCVLOWAT: c_int = os.SO_RCVLOWAT;
    pub const SO_RCVTIMEO: c_int = os.SO_RCVTIMEO;
    pub const SO_SNDBUF: c_int = os.SO_SNDBUF;
    pub const SO_SNDLOWAT: c_int = os.SO_SNDLOWAT;
    pub const SO_SNDTIMEO: c_int = os.SO_SNDTIMEO;
};

fn SOCKET(domain: u32, sock_type: u32, protocol: u32) usize {
    return system.syscall3(
        system.SYS_socket,
        @intCast(usize, domain),
        @intCast(usize, sock_type),
        @intCast(usize, protocol),
    );
}

fn LISTEN(socket: Handle, backlog: u16) usize {
    return system.syscall2(
        system.SYS_listen,
        @intCast(usize, socket),
        @intCast(usize, backlog),
    );
}

fn BIND(socket: Handle, address: *const zio.Address) usize {
    return system.syscall3(
        system.SYS_bind,
        @intCast(usize, socket),
        @ptrToInt(&address.ip),
        @intCast(usize, address.len),
    );
}

fn CONNECT(socket: Handle, address: *const zio.Address) usize {
    return system.syscall3(
        system.SYS_connect,
        @intCast(usize, socket),
        @ptrToInt(&address.ip),
        @intCast(usize, address.len),
    );
}

fn ACCEPT(socket: Handle, address: *zio.Address, flags: usize) usize {
    return system.syscall4(
        system.SYS_accept4,
        @intCast(usize, socket),
        @ptrToInt(&address.ip),
        @ptrToInt(&address.len),
        flags,
    );
}

fn READV(socket: Handle, buffers: []Buffer) usize {
    return system.syscall3(
        system.SYS_readv,
        @intCast(usize, socket),
        @ptrToInt(buffers.ptr),
        buffers.len,
    );
}

fn WRITEV(socket: Handle, buffers: []const Buffer) usize {
    return system.syscall3(
        system.SYS_writev,
        @intCast(usize, socket),
        @ptrToInt(buffers.ptr),
        buffers.len,
    );
}

fn SETSOCKOPT(socket: Handle, level: c_int, optname: c_int, optval: usize, optlen: c_int) usize {
    return system.syscall5(
        system.SYS_setsockopt,
        @intCast(usize, socket),
        @intCast(usize, level),
        @intCast(usize, optname),
        optval,
        @intCast(usize, optlen),
    );
}

fn GETSOCKOPT(socket: Handle, level: c_int, optname: c_int, optval: usize, optlen: *c_int) usize {
    return system.syscall5(
        system.SYS_getsockopt,
        @intCast(usize, socket),
        @intCast(usize, level),
        @intCast(usize, optname),
        optval,
        @ptrToInt(optlen),
    );
}