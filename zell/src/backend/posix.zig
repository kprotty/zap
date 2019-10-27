const std = @import("std");
const Task = @import("../runtime.zig").Task;
const zio = @import("../../../zap.zig").zio;
const zell = @import("../../../zap.zig").zell;

pub const Poller = struct {
    pub fn init(self: *@This(), allocator: *std.mem.Allocator) zell.Poller.Error!void {
        
    }

    pub fn deinit(self: *@This()) void {

    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) zell.Poller.SocketError!zio.Handle {

    }

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {

    }

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) zell.Poller.ConnectError!void {
        
    }

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) zell.Poller.AcceptError!zio.Handle {
        
    }

    pub fn read(self: *@This(), handle: zio.Handle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) zell.Poller.ReadError!usize {

    }

    pub fn write(self: *@This(), handle: zio.Handle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) zell.Poller.WriteError!usize {
        
    }

    pub fn poll(self: *@This(), timeout_ms: u32) zell.Poller.PollError!Task.List {

    }
};