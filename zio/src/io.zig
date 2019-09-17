const std = @import("std");
const zio = @import("../zio.zig");
const expect = std.testing.expect;

pub const Handle = zio.backend.Handle;

pub const ErrorPending = error.PendingIO;

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
    const cbuf = ConstBuffer.fromBytes(hello_world);
    expect(std.mem.eql(u8, cbuf.getBytes(), hello_world));
}

test "Buffer" {
    const hello_world = "Hello world";
    var data: [hello_world.len]u8 = undefined;
    std.mem.copy(u8, data[0..], hello_world);
    const buf = Buffer.fromBytes(data[0..]);
    expect(std.mem.eql(u8, data[0..], hello_world));
    expect(std.mem.eql(u8, buf.getBytes(), hello_world));
}

pub const StreamType = enum(u2) {
    Duplex,
    Buffered,
    ReadOnly,
    WriteOnly,
};

pub const StreamRef = struct {
    value: usize,

    pub fn new(stream_type: StreamType, value: usize) @This() {
        std.debug.assert(std.mem.isAligned(value, @alignOf(StreamType)));
        return @This() { .value = value | @enumToInt(stream_type) };
    }

    pub fn getValue(self: @This()) usize {
        return self.value & usize(~@TagType(StreamType)(0));
    }

    pub fn getType(self: @This()) StreamType {
        return @intToEnum(StreamType, @truncate(@TagType(StreamType), self.value));
    }
};

test "StreamRef" {
    const values = [_]usize { 5, 6, 7, 8 };
    const types = [_]StreamType { .Duplex, .Buffered, .ReadOnly, .WriteOnly };

    for (values) |value, index| {
        const stream_ref = StreamRef.new(types[index], value);
        expect(stream_ref.getType() == types[index]);
        expect(stream_ref.getValue() == value);
    }
}