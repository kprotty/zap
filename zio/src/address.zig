const zio = @import("../zio.zig");

pub const Address = struct {
    length: c_int,
    address: IpAddress,

    const IpAddress = packed union {
        v4: zio.backend.Socket.Ipv4,
        v6: zio.backend.Socket.Ipv6,
    };

    pub fn parseIpv4(address: []const u8, port: u16) ?@This() {
        // var addr: u32 = // TODO: ipv4 parsing
        return @This() {
            .length = @sizeOf(zio.backend.Socket.Ipv4),
            .address = IpAddress {
                .v4 = zio.backend.Socket.Ipv4.from(addr, port),
            },
        };
    }

    pub fn parseIpv6(address: []const u8, port: u16) ?@This() {
        // var addr: u128 = // TODO: ipv6 parsing
        return @This() {
            .length = @sizeOf(zio.backend.Socket.Ipv6),
            .address = IpAddress {
                .v6 = zio.backend.Socket.Ipv6.from(addr, port),
            },
        };
    }

    pub fn writeTo(self: @This(), buffer: []u8) ?void {
        // TODO: ipv4 & ipv6 serialization
        return null;
    }
};