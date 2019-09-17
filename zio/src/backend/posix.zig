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

    pub fn new(self: *@This(), flags: Flags) zio.Socket.Error!@This() {
        
    }

    pub fn fromHandle(handle: zio.Handle) @This() {
        return @This() { .handle = handle };
    }

    pub fn getHandle(self: @This()) zio.Handle {
        return self.handle;
    }

    pub fn getStreamRef(self: *const @This()) zio.StreamRef {
        return zio.StreamRef.new(.Duplex, 0);
    }

    pub const Linger = extern struct {
        l_onoff: c_int,
        l_linger: c_int,
    };

    pub fn setOption(self: *@This(), option: zio.Socket.Option) zio.Socket.OptionError!void {
        var option_ref = option;
        return switch (os.errno(socketOption(self.handle, &option_ref, Setsockopt, Options))) {
            0 => {},
            os.ENOPROTOOPT, os.EFAULT, os.EINVAL => zio.Socket.OptionError.InvalidValue,
            os.EBADF, os.ENOTSOCK => zio.Socket.OptionError.InvalidHandle,
            else => unreachable,
        };
    }

    pub fn getOption(self: @This(), option: *zio.Socket.Option) zio.Socket.OptionError!void {
        return switch (os.errno(socketOption(self.handle, &option_ref, Getsockopt, Options))) {
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

    pub fn bind(self: *@This(), address: *const zio.Address) zio.BindError!void {
        
    }

    pub fn listen(self: *@This(), backlog: c_int) zio.Socket.ListenError!void {
        
    }

    pub fn connect(self: *@This(), address: *const zio.Address) zio.Socket.ConnectError!void {
        
    }

    pub fn accept(self: *@This(), incoming: *zio.Address.Incoming) zio.Socket.AcceptError!void {
        
    }

    pub fn read(self: *@This(), address: ?*zio.Address, buffers: []Buffer) zio.Socket.DataError!usize {
        
    }

    pub fn write(self: *@This(), address: ?*const zio.Address, buffers: []ConstBuffer) zio.Socket.DataError!usize {
        
    }
};

const Options = struct {
    pub const IPPROTO_TCP = 6;
    pub const IPPROTO_UDP = 17;
    pub const TCP_NODELAY = 1;
    pub const SOL_SOCKET = os.SOL_SOCKET;
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

const C = struct {
    pub extern "c" fn getsockopt(fd: i32, level: c_int, optname: c_int, optval: usize, optlen: *c_int) usize;
    pub extern "c" fn setsockopt(fd: i32, level: c_int, optname: c_int, optval: usize, optlen: c_int) usize;
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