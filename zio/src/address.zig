

pub const Address = struct {
    length: c_int,
    sockaddr: zio.backend.SockAddr align(@alignOf(usize)),

    pub fn isIpv4(self: @This()) bool {
        return self.length == @sizeOf(zio.backend.Ipv4);
    }

    pub fn isIpv6(self: @This()) bool {
        return self.length == @sizeOf(zio.backend.Ipv6);
    }

    pub fn fromIpv4(address: u32, port: u16) @This() {
        return @This() {
            .length = @sizeOf(zio.backend.Ipv4),
            .sockaddr = zio.backend.Ipv4.from(address, port),
        };
    }

    pub fn fromIpv6(address: u128, port: u16, flowinfo: u32, scope: u32) @This() {
        return @This() {
            .length = @sizeOf(zio.backend.Ipv6),
            .sockaddr = zio.backend.Ipv6.from(address, port, flowinfo, scope),
        };
    }
};