const std = @import("std");
const expect = std.testing.expect;

const zio = @import("../../zap.zig").zio;

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

        pub fn getSocket(self: @This(), flags: zio.Socket.Flags) zio.Socket {
            return zio.Socket.fromHandle(self.handle, flags);
        }
    };

    length: c_uint,
    sockaddr: zio.backend.SockAddr,

    pub fn isIpv4(self: @This()) bool {
        return self.length == @sizeOf(zio.backend.SockAddr.Ipv4);
    }

    pub fn isIpv6(self: @This()) bool {
        return self.length == @sizeOf(zio.backend.SockAddr.Ipv6);
    }

    pub fn fromIpv4(address: u32, port: u16) @This() {
        return @This(){
            .length = @sizeOf(zio.backend.SockAddr.Ipv4),
            .sockaddr = zio.backend.SockAddr.fromIpv4(address, port),
        };
    }

    pub fn fromIpv6(address: u128, port: u16, flowinfo: u32, scope_id: u32) @This() {
        return @This(){
            .length = @sizeOf(zio.backend.SockAddr.Ipv6),
            .sockaddr = zio.backend.SockAddr.fromIpv6(address, port, flowinfo, scope_id),
        };
    }

    pub fn parseIpv4(input: []const u8) !u32 {
        if (input.len == 0)
            return u32(0);
        if (std.mem.eql(u8, input, "localhost"))
            return parse4("127.0.0.1");
        return parse4(input);
    }

    fn parse4(input: []const u8) !u32 {
        const address = try std.net.IpAddress.parse(input, 0);
        return address.in.addr;
    }

    pub fn parseIpv6(input: []const u8) !u128 {
        if (input.len == 0)
            return u128(0);
        if (std.mem.eql(u8, input, "::1"))
            return parse6("0:0:0:0:0:0:0:1");
        return parse6(input);
    }

    fn parse6(input: []const u8) !u128 {
        const address = try std.net.IpAddress.parse(input, 0);
        return @bitCast(u128, address.in6.addr);
    }
};
