const std = @import("std");
const zio = @import("../zio.zig");
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

test "Socket(Tcp) Ipv4 + Ipv6" {
    var rng = std.rand.DefaultPrng.init(0);
    const port = rng.random.intRangeLessThanBiased(u16, 1024, 65535);
    try testBlockingTcp(Ipv4Address, port);
    try testBlockingTcp(Ipv6Address, port);
}

const Ipv4Address = struct {
    pub const Flag = Socket.Ipv4;
    pub fn new(port: u16) zio.Address {
        const host = zio.Address.parseIpv4("127.0.0.1").?;
        return zio.Address.fromIpv4(host, port);
    }

    pub fn validate(address: zio.Address) bool {
        return address.isIpv4();
    }
};

const Ipv6Address = struct {
    pub const Flag = Socket.Ipv6;
    pub fn new(port: u16) zio.Address {
        const host = zio.Address.parseIpv6("::1").?;
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

    // Allow the server socket to accept incoming connections
    try server.setOption(Socket.Option { .SendTimeout = 1000 });
    try server.setOption(Socket.Option { .RecvTimeout = 1000 });
    try server.setOption(Socket.Option { .Reuseaddr = true });
    var option = Socket.Option { .Reuseaddr = undefined };
    try server.getOption(&option);
    expect(option.Reuseaddr == true);
    try server.bind(&AddressType.new(port));
    try server.listen(1);

    // Create the client socket
    var client = try Socket.new(AddressType.Flag | Socket.Tcp);
    defer client.close();

    // Connect the client socket to the server socket
    try client.setOption(Socket.Option { .SendTimeout = 1000 });
    try client.setOption(Socket.Option { .RecvTimeout = 1000 });
    try client.setOption(Socket.Option { .Tcpnodelay = true });
    try client.connect(&AddressType.new(port), 0);
    
    // Accept the incoming client from the server
    var incoming = zio.Address.Incoming.new(AddressType.new(undefined));
    try server.accept(AddressType.Flag | Socket.Tcp, &incoming, 0);
    expect(AddressType.validate(incoming.getAddressPtr().*));
    var server_client = incoming.getSocket();
    defer server_client.close();

    // send data from the servers client to the connected client
    const data = "Hello world"[0..];
    var output_buffer = [_]zio.ConstBuffer { zio.ConstBuffer.fromBytes(data) };
    var transferred = try server_client.send(null, output_buffer[0..], 0);
    expect(transferred == data.len);

    // receive the data from the connected client which was sent by the server client
    var input_data: [data.len]u8 = undefined;
    var data_buffer = [_]zio.Buffer { zio.Buffer.fromBytes(input_data[0..]) };
    transferred = try client.recv(null, data_buffer[0..], 0);
    expect(transferred == data.len);
    expect(std.mem.eql(u8, data, input_data[0..]));
}