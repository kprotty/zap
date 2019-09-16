const std = @import("std");
const zio = @import("../zio.zig");

pub const Socket = struct {
    inner: zio.backend.Socket,

    pub const Flags = u8;
    pub const Raw: Flags = 1 << 0;
    pub const Tcp: Flags = 1 << 1;
    pub const Udp: Flags = 1 << 2;
    pub const Ipv4: Flags = 1 << 3;
    pub const Ipv6: Flags = 1 << 4;

    pub const Error = error {
        // TODO
    };

    pub fn new(self: *@This(), flags: Flags) Error!@This() {
        const socket = try zio.backend.Socket.new(flags);
        return @This() { .inner = socket };
    }

    pub inline fn fromHandle(handle: zio.Handle) @This() {
        return @This() { .inner = zio.backend.Socket.fromHandle(handle) };
    }

    pub inline fn getHandle(self: @This()) zio.Handle {
        return self.inner.getHandle();
    }

    pub fn getDuplexType(self: *const @This()) zio.DuplexType {
        const duplex_type = self.inner.getDuplexType();
        std.debug.assert(duplex_type.isFull());
        return duplex_type;
    }

    const Linger = zio.backend.Socket.Linger;
    pub const Option = union(enum) {
        Debug: bool,        // SO_DEBUG
        Linger: Linger,     // SO_LINGER
        Broadcast: bool,    // SO_BROADCAST
        Reuseaddr: bool,    // SO_REUSEADDR
        Keepalive: bool,    // SO_KEEPALIVE
        Oobinline: bool,    // SO_OOBINLINE
        Tcpnodelay: bool,   // TCP_NODELAY
        RecvBufMax: c_int,  // SO_RCVBUF
        RecvBufMin: c_int,  // SO_RCVLOWAT
        RecvTimeout: c_int, // SO_RCVTIMEO
        SendBufMax: c_int,  // SO_SNDBUF
        SendBufMin: c_int,  // SO_SNDLOWAT
        SendTimeout: c_int, // SO_SNDTIMEO
    };

    pub const OptionError = error {
        // TODO
    };

    pub fn setOption(self: *@This(), option: Option) OptionError!void {
        return self.inner.setOption(option);
    }

    pub fn getOption(self: @This(), option: *Option) OptionError!void {
        return self.inner.getOption(option);
    }

    pub const BindError = error {
        // TODO
    };

    pub fn bind(self: *@This(), address: *const zio.Address) BindError!void {
        return self.inner.bind(address);
    }

    pub const ListenError = error {
        // TODO
    };

    pub fn listen(self: *@This(), backlog: c_int) ListenError!void {
        return self.inner.listen(backlog);
    }

    pub const ConnectError = error {
        // TODO
    };

    pub fn connect(self: *@This(), address: *const zio.Address) ConnectError!void {
        return self.inner.connect(address);
    }

    pub const AcceptError = error {
        // TODO
    };

    pub fn accept(self: *@This(), incoming: *zio.Address.Incoming) AcceptError!void {
        return self.inner.accept(incoming);
    }

    pub const DataError = error {
        // TODO
    };

    pub fn read(self: *@This(), address: ?*zio.Address, buffers: []zio.Buffer) DataError!usize {
        if (buffers.len == 0)
            return 0;
        return self.inner.read(address, @ptrCast([*]zio.backend.Buffer, buffers.ptr)[0..buffers.len]);
    }

    pub fn write(self: *@This(), address: ?*const zio.Address, buffers: []const zio.ConstBuffer) DataError!usize {
        if (buffers.len == 0)
            return 0;
        return self.inner.write(address, @ptrCast([*]const zio.backend.ConstBuffer, buffers.ptr)[0..buffers.len]);
    }
};
