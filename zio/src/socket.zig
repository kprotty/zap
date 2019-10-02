const std = @import("std");
const zio = @import("zap").zio;
const expect = std.testing.expect;

pub const Socket = struct {
    inner: zio.backend.Socket,

    pub const Flags = u8;
    pub const Raw: Flags = 1 << 0;
    pub const Tcp: Flags = 1 << 1;
    pub const Udp: Flags = 1 << 2;
    pub const Ipv4: Flags = 1 << 3;
    pub const Ipv6: Flags = 1 << 4;
    pub const Nonblock: Flags = 1 << 5;

    pub const Error = error {
        InvalidValue,
        InvalidState,
        OutOfResources,
    };

    pub fn new(flags: Flags) Error!@This() {
        const socket = try zio.backend.Socket.new(flags);
        return @This() { .inner = socket };
    }

    pub fn close(self: *@This()) void {
        return self.inner.close();
    }

    pub inline fn fromHandle(handle: zio.Handle) @This() {
        return @This() { .inner = zio.backend.Socket.fromHandle(handle) };
    }

    pub inline fn getHandle(self: @This()) zio.Handle {
        return self.inner.getHandle();
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
        InvalidState,
        InvalidValue,
        InvalidHandle,
    };

    pub fn setOption(self: *@This(), option: Option) OptionError!void {
        return self.inner.setOption(option);
    }

    pub fn getOption(self: @This(), option: *Option) OptionError!void {
        return self.inner.getOption(option);
    }

    pub const BindError = error {
        AddressInUse,
        InvalidState,
        InvalidHandle,
        InvalidAddress,
    };

    pub fn bind(self: *@This(), address: *const zio.Address) BindError!void {
        return self.inner.bind(address);
    }

    pub const ListenError = error {
        AddressInUse,
        InvalidState,
        InvalidHandle,
    };

    pub fn listen(self: *@This(), backlog: c_uint) ListenError!void {
        return self.inner.listen(backlog);
    }

    pub const ConnectError = zio.Error || error {
        Refused,
        TimedOut,
        InvalidState,
        InvalidHandle,
        InvalidAddress,
        AlreadyConnected,
    };

    pub fn connect(self: *@This(), address: *const zio.Address, token: usize) ConnectError!void {
        return self.inner.connect(address, token);
    }

    pub const AcceptError = zio.Error || error {
        Refused,
        InvalidHandle,
        InvalidAddress,
        OutOfResources,
    };

    pub fn accept(self: *@This(), flags: Flags, incoming: *zio.Address.Incoming, token: usize) AcceptError!void {
        return self.inner.accept(flags, &incoming.inner, token);
    }

    pub const DataError = zio.Error || error {
        InvalidValue,
        InvalidHandle,
        OutOfResources,
    };

    pub fn recv(self: *@This(), address: ?*zio.Address, buffers: []zio.Buffer, token: usize) DataError!usize {
        if (buffers.len == 0)
            return usize(0);
        return self.inner.recv(address, @ptrCast([*]zio.backend.Buffer, buffers.ptr)[0..buffers.len], token);
    }

    pub fn send(self: *@This(), address: ?*const zio.Address, buffers: []const zio.ConstBuffer, token: usize) DataError!usize {
        if (buffers.len == 0)
            return usize(0);
        return self.inner.send(address, @ptrCast([*]const zio.backend.ConstBuffer, buffers.ptr)[0..buffers.len], token);
    }
};

test "Socket(Tcp) Ipv4" {
    var rng = std.rand.DefaultPrng.init(0);
    const port = rng.random.intRangeLessThanBiased(u16, 1024, 65535);
    try testBlockingTcp(Ipv4Address, port);
    //try testBlockingTcp(Ipv6Address, port);
}

const Ipv4Address = struct {
    pub const Flag = Socket.Ipv4;

    pub fn new(port: u16) !zio.Address {
        const host = try zio.Address.parseIpv4("127.0.0.1");
        return zio.Address.fromIpv4(host, port);
    }

    pub fn validate(address: zio.Address) bool {
        return address.isIpv4();
    }
};

const Ipv6Address = struct {
    pub const Flag = Socket.Ipv6;

    pub fn new(port: u16) !zio.Address {
        const host = try zio.Address.parseIpv6("::1");
        return zio.Address.fromIpv6(host, port, 0, 0);
    }

    pub fn validate(address: zio.Address) bool {
        return address.isIpv6();
    }
};

fn testBlockingTcp(comptime AddressType: type, port: u16) !void {
    // Create the server socket
    var server = try Socket.new(AddressType.Flag | Socket.Tcp);
    defer server.close();

    
}