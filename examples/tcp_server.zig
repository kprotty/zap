const std = @import("std");
const zio = @import("zio.zig");

fn tcp_server() !void {
    // create a new tcp socket
    const socket = zio.Socket.new(
        zio.Socket.Family.Ipv4,
        zio.Socket.Protocol.Tcp
    ) orelse return error.SocketError;
    defer socket.close();

    // bind the socket to 127.0.0.1:12345
    const local = zio.Socket.Address.parseIpv4("127.0.0.1");
    const address = zio.Socket.Address.v4(local, 12345);
    _ = socket.bind(address, true) orelse return error.SocketBind;
    _ = socket.listen(128) orelse return error.SocketListen;

    // accept an incoming socket for the client
    var client_sock: zio.Socket = undefined;
    var client_addr: zio.Socket.Address = undefined;
    _ = socket.accept(&client_addr, &client_sock, null) orelse return error.SocketAccept;
    defer client_sock.close();

    // prepare 1024 bytes
    var input: [1024]u8 = undefined;
    var buffers = [_]zio.Buffer { zio.Buffer.fromSlice(input[0..]) };
    
    // read those bytes from the client
    const bytes_received = switch (client_sock.read(buffers, null, null)) {
        .Error => return error.SocketRead,
        .Transferred |received| => received,
        .RegisterRead, .RegisterWrite => unreachable, // not in async mode
        .Retry => unreachable, // byte size of sum(buffers) < std.math.maxInt(u32) and not in async mode
    };

    // write those bytes back to the client
    buffers[0] = zio.Buffer.fromSlice(input[0..bytes_received]);
    switch (client_sock.write(buffers, null, null)) {
        .Error => return error.SocketWrite,
        .Transferred |bytes_sent| => std.debug.assert(bytes_sent == bytes_received),
        else => unreachable,
    }
}

fn async_tcp_server() !void {

}

