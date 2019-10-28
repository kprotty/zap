const std = @import("std");
const builtin = @import("builtin");
const zio = @import("../../zap.zig").zio;
const Task = @import("../runtime.zig").Task;

pub const Reactor = struct {
    usingnamespace @import("./reactor/default.zig");
    usingnamespace @import("./reactor/uring.zig");

    pub const HandleType = enum {
        Socket,
    };

    pub const TypedHandle = union(HandleType) {
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
        Uring: if (builtin.os == .linux) UringReactor else DefaultReactor,
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

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) SocketError!TypedHandle {
        return switch (self.inner) {
            .Uring => |*uring| uring.socket(flags),
            .Default => |*default| default.socket(flags),
        };
    }

    pub fn close(self: *@This(), typed_handle: TypedHandle) void {
        return switch (self.inner) {
            .Uring => |*uring| uring.close(typed_handle),
            .Default => |*default| default.close(typed_handle),
        };
    }

    pub fn getHandle(self: *@This(), typed_handle: TypedHandle) zio.Handle {
        return switch (self.inner) {
            .Uring => |*uring| uring.getHandle(typed_handle),
            .Default => |*default| default.getHandle(typed_handle),
        };
    }

    pub fn setsockopt(self: *@This(), typed_handle: TypedHandle, option: zio.Socket.Option) zio.Socket.OptionError!void {
        if (HandleType(typed_handle) != .Socket)
            return zio.Socket.OptionError.InvalidHandle;
        var sock = zio.Socket.fromHandle(self.getHandle(typed_handle), zio.Socket.Nonblock);
        return sock.setOption(option);
    }

    pub fn getsockopt(self: *@This(), typed_handle: TypedHandle, option: *zio.Socket.Option) zio.Socket.OptionError!void {
        if (HandleType(typed_handle) != .Socket)
            return zio.Socket.OptionError.InvalidHandle;
        var sock = zio.Socket.fromHandle(self.getHandle(typed_handle), zio.Socket.Nonblock);
        return sock.getOption(option);
    }

    pub fn bind(self: *@This(), typed_handle: TypedHandle, address: *const zio.Address) zio.Socket.BindError!void {
        if (HandleType(typed_handle) != .Socket)
            return zio.Socket.OptionError.InvalidHandle;
        var sock = zio.Socket.fromHandle(self.getHandle(typed_handle), zio.Socket.Nonblock);
        return sock.bind(address);
    }

    pub fn listen(self: *@This(), typed_handle: TypedHandle, backlog: c_uint) zio.Socket.ListenError!void {
        if (HandleType(typed_handle) != .Socket)
            return zio.Socket.OptionError.InvalidHandle;
        var sock = zio.Socket.fromHandle(self.getHandle(typed_handle), zio.Socket.Nonblock);
        return sock.listen(address);
    }

    pub const AcceptError = zio.Socket.RawAcceptError || error{Closed} || zio.Event.Poller.RegisterError;

    pub fn accept(self: *@This(), typed_handle: TypedHandle, address: *zio.Address) AcceptError!TypedHandle {
        return switch (self.inner) {
            .Uring => |*uring| uring.accept(typed_handle, address),
            .Default => |*default| default.accept(typed_handle, address),
        };
    }

    pub const ConnectError = zio.Socket.RawConnectError || error{Closed};

    pub fn connect(self: *@This(), typed_handle: TypedHandle, address: *const zio.Address) ConnectError!void {
        return switch (self.inner) {
            .Uring => |*uring| uring.connect(typed_handle, address),
            .Default => |*default| default.connect(typed_handle, address),
        };
    }

    pub const ReadError = zio.Socket.RawDataError || error{Closed};

    pub fn read(self: *@This(), typed_handle: TypedHandle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) ReadError!usize {
        return switch (self.inner) {
            .Uring => |*uring| uring.read(typed_handle, address, buffer, offset),
            .Default => |*default| default.read(typed_handle, address, buffer, offset),
        };
    }

    pub const WriteError = zio.Socket.RawDataError || error{Closed};

    pub fn write(self: *@This(), typed_handle: TypedHandle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) WriteError!usize {
        return switch (self.inner) {
            .Uring => |*uring| uring.write(typed_handle, address, buffer, offset),
            .Default => |*default| default.write(typed_handle, address, buffer, offset),
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

test "Reactor - Socket" {
    var reactor: Reactor = undefined;
    try reactor.init(std.debug.global_allocator);
    defer reactor.deinit();
}
