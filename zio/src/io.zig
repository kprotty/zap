const std = @import("std");
const zio = @import("../zio.zig");

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

pub const DuplexType = struct {
    const FULL: usize = 1 << 0;
    const HALF: usize = 1 << 1;

    value: usize,

    pub fn getValue(self: @This()) usize {
        return self.value & ~(FULL | HALF);
    }

    pub fn isFull(self: @This()) bool {
        return (self.value & FULL) != 0;
    }

    pub fn isHalf(self: @This()) bool {
        return (self.value & HALF) != 0;
    }

    pub fn Full(value: usize) @This() {
        return @This() { .value = value | FULL };
    }

    pub fn Half(value: usize) @This() {
        return @This() { .value = value | HALF };
    }
};