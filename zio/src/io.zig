const std = @import("std");
const expect = std.testing.expect;
const zio = @import("../../zap.zig").zio;

pub const Handle = zio.backend.Handle;

pub const Error = struct {
    pub const Closed = Set.Closed;
    pub const Pending = Set.Pending;
    pub const InvalidToken = Set.InvalidToken;

    pub const Set = error {
        Closed,
        Pending,
        InvalidToken,
    };
};

pub const Buffer = struct {
    inner: zio.backend.Buffer,

    pub fn getBytes(self: @This()) []u8 {
        return self.inner.getBytes();
    }

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This(){ .inner = zio.backend.Buffer.fromBytes(bytes) };
    }
};

test "Buffer" {
    const hello_world = "Hello world";
    var data: [hello_world.len]u8 = undefined;
    std.mem.copy(u8, data[0..], hello_world);
    const buffer = Buffer.fromBytes(data[0..]);
    expect(std.mem.eql(u8, data[0..], hello_world));
    expect(std.mem.eql(u8, buffer.getBytes(), hello_world));
}
