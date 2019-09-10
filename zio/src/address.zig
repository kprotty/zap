const zio = @import("../zio.zig");

pub const Address = struct {
    len: u8,
    data: SockAddr,

    const SockAddr = packed union {
        v4: zio.backend.Ipv4,
        v6: zio.backend.Ipv6,
    };

    pub inline fn isIpv4(self: @This()) bool {
        return self.len == @sizeOf(zio.backend.Ipv4);
    }

    pub inline fn isIpv6(self: @This()) bool {
        return self.len == @sizeOf(zio.backend.Ipv6);
    }

    pub inline fn fromIpv4(address: u32, port: u16) @This() {
        return @This() {
            .len = @sizeOf(zio.backend.Ipv4),
            .data = SockAddr { .v4 = zio.backend.Ipv4.from(address, port), }
        };
    }

    pub inline fn fromIpv6(address: u128, port: u16, flow: u32, scope: u32) @This() {
        return @This() {
            .len = @sizeOf(zio.backend.Ipv6),
            .data = SockAddr { .v6 = zio.backend.Ipv6.from(address, port, flow, scope), }
        };
    }

    pub fn parseIpv4(input: []const u8) u32 {
        return 0; // TODO
    }

    pub fn parseIpv6(input: []const u8) u128 {
        return 0; // TODO
    }
};