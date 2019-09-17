const std = @import("std");
const builtin = @import("builtin");
const zio = @import("../../zio.zig");

const os = std.os;
const system = os.system;

pub const Handle = i32;

pub const Buffer = struct {
    inner: os.iovec,

    pub fn getBytes(self: @This()) []u8 {
        return self.inner.iov_base[0..self.inner.iov_len];
    }

    pub fn fromBytes(bytes: []u8) @This() {
        return @This() {
            .inner = os.iovec {
                .iov_base = bytes.ptr,
                .iov_len = bytes.len,
            }
        };
    }
};

pub const ConstBuffer = struct {
    inner: os.iovec_const,

    pub fn getBytes(self: @This()) []const u8 {
        return self.inner.iov_base[0..self.inner.iov_len];
    }

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This() {
            .inner = os.iovec_const {
                .iov_base = bytes.ptr,
                .iov_len = bytes.len,
            }
        };
    }
};

pub const Socket = struct {
    handle: Handle,

    pub fn new(self: *@This(), flags: Flags) zio.Socket.Error!@This() {
        
    }

    pub fn fromHandle(handle: zio.Handle) @This() {
        
    }

    pub fn getHandle(self: @This()) zio.Handle {
        
    }

    pub fn getStreamRef(self: *const @This()) zio.StreamRef {
        
    }

    const Linger = switch (builtin.os) {
        .linux => // TODO,
        else => // TODO
    };

    pub fn setOption(self: *@This(), option: zio.Socket.Option) zio.Socket.OptionError!void {
        
    }

    pub fn getOption(self: @This(), option: *zio.Socket.Option) zio.Socket.OptionError!void {
        
    }

    pub fn bind(self: *@This(), address: *const zio.Address) zio.BindError!void {
        
    }

    pub fn listen(self: *@This(), backlog: c_int) zio.Socket.ListenError!void {
        
    }

    pub fn connect(self: *@This(), address: *const zio.Address) zio.Socket.ConnectError!void {
        
    }

    pub fn accept(self: *@This(), incoming: *zio.Address.Incoming) zio.Socket.AcceptError!void {
        
    }

    pub fn read(self: *@This(), address: ?*zio.Address, buffers: []Buffer) zio.Socket.DataError!usize {
        
    }

    pub fn write(self: *@This(), address: ?*const zio.Address, buffers: []ConstBuffer) zio.Socket.DataError!usize {
        
    }
};