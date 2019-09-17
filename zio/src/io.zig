const std = @import("std");
const zio = @import("../zio.zig");
const expect = std.testing.expect;

pub const Handle = zio.backend.Handle;

pub const ErrorClosed = error.Closed;
pub const ErrorPending = error.Pending;

pub const Buffer = struct {
    inner: zio.backend.Buffer,

    pub fn getBytes(self: @This()) []u8 {
        return self.inner.getBytes();
    }

    pub fn fromBytes(bytes: []u8) @This() {
        return @This() { .inner = zio.backend.Buffer.fromBytes(bytes) };
    }
};

pub const ConstBuffer = struct {
    inner: zio.backend.ConstBuffer,

    pub fn getBytes(self: @This()) []const u8 {
        return self.inner.getBytes();
    }

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This() { .inner = zio.backend.ConstBuffer.fromBytes(bytes) };
    }
};

test "ConstBuffer" {
    const hello_world = "Hello world";
    const buffer = ConstBuffer.fromBytes(hello_world);
    expect(std.mem.eql(u8, buffer.getBytes(), hello_world));
}

test "Buffer" {
    const hello_world = "Hello world";
    var data: [hello_world.len]u8 = undefined;
    std.mem.copy(u8, data[0..], hello_world);
    const buffer = Buffer.fromBytes(data[0..]);
    expect(std.mem.eql(u8, data[0..], hello_world));
    expect(std.mem.eql(u8, buffer.getBytes(), hello_world));
}
