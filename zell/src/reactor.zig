const std = @import("std");
const builtin = @import("builtin");

const Task = @import("runtime.zig").Task;
const zio = @import("../../zap.zig").zio;
const zell = @import("../../zap.zig").zell;

const os = std.os;
const expect = std.testing.expect;

pub const Reactor = struct {
    inner: zell.backend.Reactor,
    
    pub const InitError = zio.Event.Poller.Error;

    pub fn init(self: *@This()) InitError!void {
        return self.inner.init();
    }

    pub fn deinit(self: *@This()) void {
        return self.inner.deinit();
    }

    pub const NotifyError = zio.Event.Poller.NotifyError;

    pub fn notify(self: *@This()) NotifyError!void {
        return self.inner.notify();
    }

    pub const OpenError = error {
        TODO,
    };

    pub fn open(self: *@This(), path: []const u8, flags: u32) OpenError!zio.Handle {
        return self.inner.open(path, flags);
    }

    pub const FsyncError = error {
        TODO,
    };

    pub fn fsync(self: *@This(), handle: zio.Handle, flags: u32) FsyncError!void {
        return self.inner.fsync(handle, flags);
    }

    pub const SocketError = error {

    };

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) SocketError!zio.Handle {
        return self.inner.socket(flags);
    }

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {
        return self.inner.close(handle, is_socket);
    }

    pub const ConnectError = error {

    };

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) ConnectError!void {
        return self.inner.connect(handle, address);
    }

    pub const AcceptError = error {

    };

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) AcceptError!zio.Handle {
        return self.inner.accept(handle, address);
    }

    pub const ReadError = error {

    };

    pub fn readv(self: *@This(), address: ?*zio.Address, buffer: []const []u8, offset: ?u64) ReadError!usize {
        return self.inner.readv(address, buffer, offset);
    }

    pub const WriteError = error {

    };

    pub fn writev(self: *@This(), address: ?*zio.Address, buffer: []const []const u8, offset: ?u64) WriteError!usize {
        return self.inner.writev(address, buffer, offset);
    }

    pub const PollError = error {

    };

    pub fn poll(self: *@This(), timeout_ms: ?u32) PollError!Task.List {
        return self.inner.poll(timeout_ms);
    }
};
