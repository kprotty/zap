const zio = @import("../zio.zig");

/// A sum-type of an Ipv4 address and an Ipv6 address.
/// The length is stored in order to not require extra
/// arguments for socket functions which store the len.
pub const Address = struct {
    len: u32,
    ip: SockAddr align(@alignOf(usize)),

    /// Union for easier type access
    pub const SockAddr = extern union {
        v4: zio.backend.Ipv4,
        v6: zio.backend.Ipv6,
    };

    /// Data structure used for accepting 
    /// incoming Socket clients with an ip address.
    pub const Incoming = struct {
        inner: zio.backend.Incoming,

        /// Create an incoming address using the ip address provided
        pub fn from(address: Address) @This() {
            return @This() { .inner = zio.backend.Incoming.from(address) };
        }

        /// Once filled by the backend, get the client socket from the Incoming
        pub fn getSocket(self: @This()) zio.Socket {
            return zio.Socket { .inner = self.inner.getSocket() };
        }

        /// Once filled by the backend, get the remote address from the Incoming
        /// This should be of the same type passed into `from()`.
        pub fn getAddress(self: @This()) Address {
            return self.inner.getAddress();
        }
    };

    /// Returns where the internal variant is an ipv4
    pub fn isIpv4(self: @This()) bool {
        return self.len == @sizeOf(zio.backend.Ipv4);
    }

    /// Returns where the internal variant is an ipv6
    pub fn isIpv6(self: @This()) bool {
        return self.len == @sizeOf(zio.backend.Ipv6);
    }

    /// Create an Ipv4 Address using the given parameters
    pub fn fromIpv4(address: u32, port: u16) @This() {
        return @This() {
            .len = @sizeOf(zio.backend.Ipv4),
            .ip = SockAddr { .v4 = zio.backend.Ipv4.from(address, port), }
        };
    }

    /// Create an Ipv6 Address using the given parameters
    pub fn fromIpv6(address: u128, port: u16, flow: u32, scope: u32) @This() {
        return @This() {
            .len = @sizeOf(zio.backend.Ipv6),
            .ip = SockAddr { .v6 = zio.backend.Ipv6.from(address, port, flow, scope), }
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