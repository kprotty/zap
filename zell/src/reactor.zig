const std = @import("std");
const builtin = @import("builtin");
const zio = @import("../../zap.zig").zio;
const Task = @import("../runtime.zig").Task;

pub const Reactor = struct {
    usingnamespace @import("./reactor/default.zig");
    usingnamespace @import("./reactor/uring.zig");

    pub const Handle = union(enum) {
        Socket: usize,

        pub fn getValue(self: @This()) usize {
            return switch (self) {
                .Socket => |value| value,
            };
        }
    };

    inner: Inner,
    const Inner = union(enum) {
        Default: DefaultReactor,
        Uring: if (builtin.os == .linux) UringReactor else void,
    };

    pub const Error = zio.Event.Poller.Error;

    pub fn init(self: *@This(), allocator: *std.mem.Allocator) Error!void {
        if (builtin.os == .linux and UringPoller.isSupported()) {
            self.inner = Inner{ .Uring = undefined };
            return self.inner.Uring.init(allocator);
        } else {
            self.inner = Inner{ .Default = undefined };
            return self.inner.Default.init(allocator);
        }
    }

    pub fn deinit(self: *@This()) void {
        return switch (self.inner) {
            .Uring => |*uring| uring.deinit(),
            .Default => |*default| default.deinit(),
        };
    }

    pub const SocketError = zio.Socket.Error || zio.Event.Poller.RegisterError;

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) SocketError!Handle {
        return switch (self.inner) {
            .Uring => |*uring| uring.socket(flags),
            .Default => |*default| default.socket(flags),
        };
    }

    pub fn close(self: *@This(), handle: Handle) void {
        return switch (self.inner) {
            .Uring => |*uring| uring.close(typed_handle),
            .Default => |*default| default.close(typed_handle),
        };
    }

    pub const AcceptError = zio.Socket.RawAcceptError || error{Closed} || zio.Event.Poller.RegisterError;

    pub fn accept(self: *@This(), handle: Handle, address: *zio.Address) AcceptError!Handle {
        return switch (self.inner) {
            .Uring => |*uring| uring.accept(handle, address),
            .Default => |*default| default.accept(handle, address),
        };
    }

    pub const ConnectError = zio.Socket.RawConnectError || error{Closed};

    pub fn connect(self: *@This(), handle: Handle, address: *const zio.Address) ConnectError!void {
        return switch (self.inner) {
            .Uring => |*uring| uring.connect(handle, address),
            .Default => |*default| default.connect(handle, address),
        };
    }

    pub const ReadError = zio.Socket.RawDataError || error{Closed};

    pub fn read(self: *@This(), handle: Handle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) ReadError!usize {
        return switch (self.inner) {
            .Uring => |*uring| uring.read(handle, address, buffer, offset),
            .Default => |*default| default.read(handle, address, buffer, offset),
        };
    }

    pub const WriteError = zio.Socket.RawDataError || error{Closed};

    pub fn write(self: *@This(), handle: Handle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) WriteError!usize {
        return switch (self.inner) {
            .Uring => |*uring| uring.write(handle, address, buffer, offset),
            .Default => |*default| default.write(handle, address, buffer, offset),
        };
    }

    pub const NotifyError = zio.Event.Poller.NotifyError;

    pub fn notify(self: *@This()) NotifyError!void {
        return switch (self.inner) {
            .Uring => |*uring| uring.notify(),
            .Default => |*default| default.notify(),
        };
    }

    pub const PollError = zio.Event.Poller.PollError;

    pub fn poll(self: *@This(), timeout_ms: ?u32) PollError!Task.List {
        return switch (self.inner) {
            .Uring => |*uring| uring.poll(timeout_ms),
            .Default => |*default| default.poll(timeout_ms),
        };
    }
};
