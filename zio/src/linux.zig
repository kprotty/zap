const std = @import("std");
const zio = @import("../zio.zig");

const linux = std.os.linux;
const posix = @import("posix.zig");

pub const Handle = posix.Handle;

pub fn Initialize() zio.InitError!void {
    return posix.Initialize();
}

pub fn Cleanup() void {
    return posix.Cleanup();
}

pub const Buffer = posix.Buffer;

pub const EventPoller = struct {

    pub fn getHandle(self: @This()) Handle {
        // TODO
    }

    pub fn fromHandle(handle: Handle) @This() {
        // TODO
    }

    pub fn init(self: *@This()) zio.EventPoller.Error!void {
        // TODO
    }

    pub fn close(self: *@This()) void {
        // TODO
    }

    pub fn register(self: *@This(), handle: Handle, flags: u32, data: usize) zio.EventPoller.RegisterError!void {
        // TODO
    }

    pub fn reregister(self: *@This(), handle: Handle, flags: u32, data: usize) zio.EventPoller.RegisterError!void {
        // TODO
    }

    pub fn notify(self: *@This(), data: usize) zio.EventPoller.NotifyError!void {
        // TODO
    }

    pub const Event = packed struct {

        pub fn getData(self: @This()) usize {
            // TODO
        }

        pub fn getResult(self: @This()) zio.Result {
            // TODO
        }

        pub fn getIdentifier(self: @This()) usize {
            // TODO
        }
    };

    pub fn poll(self: *@This(), events: []Event, timeout: ?u32) zio.EventPoller.PollError![]Event {
        // TODO   
    }
};

pub const Socket = struct {

    pub fn getHandle(self: @This()) Handle {
        // TODO
    }

    pub fn fromHandle(handle: Handle) @This() {
        // TODO
    }

    pub fn init(self: *@This(), flags: u32) zio.Socket.Error!void {
        // TODO
    }
    
    pub fn close(self: *@This()) void {
        // TODO
    }

    pub fn isReadable(self: *@This(), identifier: usize) bool {
        // TODO
    }

    pub fn isWriteable(self: *@This(), identifier: usize) bool {
        // TODO
    }

    pub fn setOption(option: Option) zio.Socket.OptionError!void {
        // TODO
    }

    pub fn getOption(option: *Option) zio.Socket.OptionError!void {
        // TODO
    }

    pub fn read(self: *@This(), buffers: []zio.Buffer) zio.Result {
        // TODO
    }

    pub fn write(self: *@This(), buffers: []const zio.Buffer) zio.Result {
        // TODO
    }

    pub const Ipv4 = packed struct {

        pub fn from(address: u32, port: u16) @This() {
            // TODO
        }
    };

    pub const Ipv6 = packed struct {

        pub fn from(address: u128, port: u16) @This() {
            // TODO
        }
    };

    pub fn bind(self: *@This(), address: *zio.Socket.Address) zio.Socket.BindError!void {
        // TODO
    }

   
    pub fn listen(self: *@This(), backlog: u16) zio.Socket.ListenError!void {
        // TODO
    }

    pub fn accept(self: *@This(), address: *zio.Socket.Address) zio.Result {
        // TODO
    }

    pub fn connect(self: *@This(), address: *zio.Socket.Address) zio.Result {
        // TODO
    }
};
