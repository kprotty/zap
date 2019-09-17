const std = @import("std");
const builtin = @import("builtin");
const zio = @import("../../zio.zig");

const os = std.os;
const system = os.system;

pub const Handle = i32;

pub const Buffer = struct {
    inner: os.iovec,

    pub fn getBytes(self: @This()) []u8 {
        return self.inner.iov_base[0..self.inner.iov_len];
    }

    pub fn fromBytes(bytes: []u8) @This() {
        return @This() {
            .inner = os.iovec {
                .iov_base = bytes.ptr,
                .iov_len = bytes.len,
            }
        };
    }
};

pub const ConstBuffer = struct {
    inner: os.iovec_const,

    pub fn getBytes(self: @This()) []const u8 {
        return self.inner.iov_base[0..self.inner.iov_len];
    }

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This() {
            .inner = os.iovec_const {
                .iov_base = bytes.ptr,
                .iov_len = bytes.len,
            }
        };
    }
};

pub const Socket = struct {
    handle: Handle,

    pub fn new(self: *@This(), flags: zio.Socket.Flags) zio.Socket.Error!@This() {
        
    }

    pub fn fromHandle(handle: zio.Handle) @This() {
        return @This() { .handle = handle };
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
        return switch (errno(socketOption(self.handle, &option_ref, Getsockopt, Options))) {
            0 => {},
            os.ENOPROTOOPT, os.EFAULT, os.EINVAL => zio.Socket.OptionError.InvalidValue,
            os.EBADF, os.ENOTSOCK => zio.Socket.OptionError.InvalidHandle,
            else => unreachable,
        };
    }

    pub fn socketOption(
        handle: zio.Handle,
        option: *zio.Socket.Option,
        comptime sockopt: var,
        comptime flags: type,
    ) @typeOf(sockopt).ReturnType {
        var value: c_int = undefined;
        var level: c_int = flags.SOL_SOCKET;
        var optname: c_int = undefined;
        var optval: usize = @ptrToInt(&value);
        var optlen: c_int = @sizeOf(@typeOf(value));
        const is_setter = @typeInfo(@typeOf(sockopt)).Fn.args[4].arg_type == c_int;

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
            .RecvBufMax => |value| {
                if (is_setter) number = value;
                optname = flags.SO_RCVBUF;
            },
            .RecvBufMin => |value| {
                if (is_setter) number = value;
                optname = flags.SO_RCVLOWAT;
            },
            .RecvTimeout => |value| {
                if (is_setter) number = value;
                optname = flags.SO_RCVTIMEO;
            },
            .SendBufMax => |value| {
                if (is_setter) number = value;
                optname = flags.SO_SNDBUF;
            },
            .SendBufMin => |value| {
                if (is_setter) number = value;
                optname = flags.SO_SNDLOWAT;
            },
            .SendTimeout => |value| {
                if (is_setter) number = value;
                optname = flags.SO_SNDTIMEO;
            },
        }

        if (is_setter)
            return sockopt(handle, level, optname, optval, optlen);
        const result = sockopt(handle, level, optname, optval, &optlen);
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
        std.debug.assert(token == 0 or (token & zio.Event.Writeable) != 0);
        if ((token & zio.Event.Disposable) != 0)
                return zio.ErrorClosed;
        if ((token & zio.Event.Writeable) != 0) {
            var errno_len: c_int = undefined;
            var errno_value: c_int = undefined;
            if (Getsockopt(self.handle, Options.SOL_SOCKET, options.SO_ERROR, &errno_value, &errno_len) != 0)
                return zio.Socket.ConnectError.InvalidHandle;
            if (errno_value <= 0)
                return;
            _ = try getConnectError(@intCast(u16, errno_value));
        }

        while (getConnectError(errno(Connect(self.handle, address))) catch |err| return err)
            {}
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
        };
    }

    pub fn accept(self: *@This(), flags: zio.Socket.Flags, incoming: *zio.Address.Incoming, token: usize) zio.Socket.AcceptError!void {
        std.debug.assert(token == 0 or (token & zio.Event.Readable) != 0);
        if ((token & zio.Event.Disposable) != 0)
            return zio.ErrorClosed;

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
            }
        }
    }

    pub fn read(self: *@This(), address: ?*zio.Address, buffers: []Buffer, token: usize) zio.Socket.DataError!usize {
        std.debug.assert(token == 0 or (token & zio.Event.Readable) != 0);
        if ((token & zio.Event.Disposable) != 0)
            return zio.ErrorClosed;
        return transfer(sel.fhandle, address, buffers, Recvmsg);
    }

    pub fn write(self: *@This(), address: ?*const zio.Address, buffers: []const ConstBuffer, token: usize) zio.Socket.DataError!usize {
        std.debug.assert(token == 0 or (token & zio.Event.Writeable) != 0);
        if ((token & zio.Event.Disposable) != 0)
            return zio.ErrorClosed;
        return transfer(self.handle, address, buffers, Sendmsg);
    }

    fn transfer(handle: zio.Handle, address: var, buffers: var, comptime Transfer: var) zio.Socket.DataError!usize {
        var message_header = msghdr {
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
    msg_flags: c_int,
};

const C = struct {
    pub extern "c" fn getsockopt(fd: i32, level: c_int, optname: c_int, optval: usize, optlen: *c_int) usize;
    pub extern "c" fn setsockopt(fd: i32, level: c_int, optname: c_int, optval: usize, optlen: c_int) usize;
    pub extern "c" fn accept4(fd: i32, addr: *os.sockaddr, len: c_uint, flags: c_uint) usize;
    pub extern "c" fn connect(fd: i32, addr: *const os.sockaddr, len: c_int) usize;
    pub extern "c" fn bind(fd: i32, addr: *const os.sockaddr, len: c_uint) usize;
    pub extern "c" fn sendmsg(fd: i32, msg: *const msghdr, flags: c_int) usize;
    pub extern "c" fn recvmsg(fd: i32, msg: *msghdr, flags: c_int) usize;
    pub extern "c" fn listen(fd: i32, backlog: c_uint) usize;
};

inline fn errno(value: usize) u16 {
    if (builtin.os != .linux)
        return os.errno(@bitCast(isize, value));
    return os.errno(value);
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
        return C.accept4(fd, @ptrCast(*os.sockaddr, &address.sockaddr), address.length, flags);
    return system.syscall4(
        system.SYS_accept4,
        @intCast(usize, fd),
        @ptrToInt(&address.sockaddr),
        @intCast(usize, address.length),
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
    return system.syscall3(
        system.SYS_listen,
        @intCast(usize, fd),
        @intCast(usize, backlog),
    );
}