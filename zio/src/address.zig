const std = @import("std");
const expect = std.testing.expect;

const zio = @import("zap").zio;

pub const Address = extern struct {
    pub const Incoming = extern struct {
        handle: zio.Handle,
        address: zio.Address,
        padding: [zio.backend.IncomingPadding]u8,

        pub fn new(address: Address) @This() {
            var self: @This() = undefined;
            self.address = address;
            return self;
        }

        pub fn getSocket(self: @This()) zio.Socket {
            return zio.Socket.fromHandle(self.handle);
        }
    };

    length: c_uint,
    sockaddr: zio.backend.SockAddr align(@alignOf(usize)),

    pub fn isIpv4(self: @This()) bool {
        return self.length == @sizeOf(zio.backend.SockAddr.Ipv4);
    }

    pub fn isIpv6(self: @This()) bool {
        return self.length == @sizeOf(zio.backend.SockAddr.Ipv6);
    }

    pub fn fromIpv4(address: u32, port: u16) @This() {
        return @This() {
            .length = @sizeOf(zio.backend.SockAddr.Ipv4),
            .sockaddr = zio.backend.SockAddr.fromIpv4(address, port),
        };
    }

    pub fn fromIpv6(address: std.net.Ip6Addr, port: u16, flowinfo: u32) @This() {
        return @This() {
            .length = @sizeOf(zio.backend.SockAddr.Ipv6),
            .sockaddr = zio.backend.SockAddr.fromIpv6(@bitCast(u128, address.addr), port, flowinfo, address.scope_id),
        };
    }

    pub fn parseIpv4(input: []const u8) !u32 {
        if (input.len == 0)
            return u32(0);
        if (std.mem.eql(u8, input, "localhost"))
            return std.net.parseIp4("127.0.0.1");
        return std.net.parseIp4(input);
    }

    pub fn parseIpv6(input: []const u8) !std.net.Ip6Addr { 
        if (input.len == 0)
            return std.net.Ip6Addr { .scope_id = 0, .addr = [_]u8 { 0 } ** 16 };
        if (std.mem.eql(u8, input, "::1"))
            return std.net.parseIp6("0:0:0:0:0:0:0:1");
        return std.net.parseIp6(input);
    }
};
