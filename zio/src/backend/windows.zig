const std = @import("std");
const posix = @import("posix.zig");
const zio = @import("../../zio.zig");

const windows = std.os.windows;

pub const Handle = windows.HANDLE;

pub const Buffer = struct {
    inner: WSABUF,

    pub fn getBytes(self: @This()) []u8 {
        return self.inner.buf[0..self.inner.len];
    }

    pub fn fromBytes(bytes: []u8) @This() {
        return @This() {
            .inner = WSABUF {
                .buf = bytes.ptr,
                .len = @intCast(windows.DWORD, bytes.len),
            }
        };
    }
};

pub const ConstBuffer = struct {
    inner: WSABUF,

    pub fn getBytes(self: @This()) []u8 {
        return self.inner.buf[0..self.inner.len];
    }

    pub fn fromBytes(bytes: []u8) @This() {
        return @This() {
            .inner = WSABUF {
                .buf = bytes.ptr,
                .len = @intCast(windows.DWORD, bytes.len),
            }
        };
    }
};

pub const Socket = struct {
    handle: Handle,

    pub fn new(self: *@This(), flags: zio.Socket.Flags) zio.Socket.Error!@This() {
        
    }

    pub fn fromHandle(handle: zio.Handle) @This() {
        
    }

    pub fn getHandle(self: @This()) zio.Handle {
        
    }

    const Linger = //

    pub fn setOption(self: *@This(), option: zio.Socket.Option) zio.Socket.OptionError!void {
        
    }

    pub fn getOption(self: @This(), option: *zio.Socket.Option) zio.Socket.OptionError!void {
        
    }

    pub fn bind(self: *@This(), address: *const zio.Address) zio.Socket.BindError!void {
        
    }

    pub fn listen(self: *@This(), backlog: c_uint) zio.Socket.ListenError!void {
        
    }

    pub fn connect(self: *@This(), address: *const zio.Address, event: ?zio.backend.Event) zio.Socket.ConnectError!void {
        
    }

    pub fn accept(self: *@This(), flags: zio.Socket.Flags, incoming: *zio.Address.Incoming, event: ?zio.backend.Event) zio.Socket.AcceptError!void {
        
    }

    pub fn read(self: *@This(), address: ?*zio.Address, buffers: []Buffer, event: ?zio.backend.Event) zio.Socket.DataError!usize {
        
    }

    pub fn write(self: *@This(), address: ?*const zio.Address, buffers: []const ConstBuffer, event: ?zio.backend.Event) zio.Socket.DataError!usize {
        
    }
};