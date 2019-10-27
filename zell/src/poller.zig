const std = @import("std");
const zio = @import("../../zap.zig").zio;
const zell = @import("../../zap.zig").zell;
const Task = @import("../runtime.zig").Task;

pub const Poller = struct {
    inner: zell.backend.Poller,

    pub const Error = zio.Event.Poller.Error;

    pub fn init(self: *@This(), allocator: *std.mem.Allocator) Error!void {
        return self.inner.init(allocator);
    }

    pub fn deinit(self: *@This()) void {
        return self.inner.deinit();
    }

    pub const SocketError = zio.Socket.Error || zio.Event.Poller.RegisterError;

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) SocketError!zio.Handle {
        return self.inner.socket(flags);
    }

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {
        return self.inner.close(handle, is_socket);
    }

    pub const ConnectError = zio.Socket.RawConnectError || error { zio.Error.Closed };

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) ConnectError!void {
        return self.inner.connect(handle, address);
    }

    pub const AcceptError = zio.Socket.RawAcceptError || error { zio.Error.Closed };

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) AcceptError!zio.Handle {
        return self.inner.accept(handle, address);
    }

    pub const ReadError = zio.Socket.RawDataError || error { zio.Error.Closed };

    pub fn read(self: *@This(), handle: zio.Handle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) ReadError!usize {
        return self.inner.read(handle, address, buffer, offset);
    }

    pub const WriteError = zio.Socket.RawDataError || error { zio.Error.Closed };

    pub fn write(self: *@This(), handle: zio.Handle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) WriteError!usize {
        return self.inner.write(handle, address, buffer, offset);
    }

    pub const PollError = zio.Event.Poller.PollError;

    pub fn poll(self: *@This(), timeout_ms: u32) PollError!Task.List {
        return self.inner.poll(timeout_ms);
    }
};