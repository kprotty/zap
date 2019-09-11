const zio = @import("../zio.zig");

/// A sum-type of an Ipv4 address and an Ipv6 address.
/// The length is stored in order to not require extra
/// arguments for socket functions which store the len.
pub const Address = struct {
    len: u32,
    ip: SockAddr,

    /// Union for easier type access
    const SockAddr = extern union {
        v4: zio.backend.Ipv4,
        v6: zio.backend.Ipv6,
    };

    /// Data structure used for accepting 
    /// incoming IO handles with an ip address.
    pub const Incoming = packed struct {
        handle: zio.Handle,
        address: Address,
        padding: [@sizeOf(Address) + @sizeOf(zio.Handle) - zio.backend.IncomingPadding]u8,
    };

    /// Returns where the internal variant is an ipv4
    pub inline fn isIpv4(self: @This()) bool {
        return self.len == @sizeOf(zio.backend.Ipv4);
    }

    /// Returns where the internal variant is an ipv6
    pub inline fn isIpv6(self: @This()) bool {
        return self.len == @sizeOf(zio.backend.Ipv6);
    }

    /// Create an Ipv4 Address using the given parameters
    pub inline fn fromIpv4(address: u32, port: u16) @This() {
        return @This() {
            .len = @sizeOf(zio.backend.Ipv4),
            .data = SockAddr { .v4 = zio.backend.Ipv4.from(address, port), }
        };
    }

    /// Create an Ipv6 Address using the given parameters
    pub inline fn fromIpv6(address: u128, port: u16, flow: u32, scope: u32) @This() {
        return @This() {
            .len = @sizeOf(zio.backend.Ipv6),
            .data = SockAddr { .v6 = zio.backend.Ipv6.from(address, port, flow, scope), }
        };
    }

    /// Given a string of unicode bytes, parse an ipv4 address from it
    pub fn parseIpv4(input: []const u8) u32 {
        return 0; // TODO
    }

    /// Given a string of unicode bytes, parse an ipv6 address from it
    pub fn parseIpv6(input: []const u8) u128 {
        return 0; // TODO
    }
};