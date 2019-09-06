const std = @import("std");
const system = std.os.system;
const zio = @import("../zio.zig");

pub const Handle = i32;

// needs to throw some type of error for the compiler to not complain :/
var dummy_var: usize = 0;
pub fn Initialize() zio.InitError!void {
    if (@ptrCast(*volatile usize, &dummy_var).* != 0)
        return zio.InitError.InvalidSystemState;
}

pub fn Cleanup() void {
    // nothing to do here, keep scrolling
}

pub const Buffer = packed struct {
    inner: system.iovec_const,

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This() {
            .inner = system.iovec {
                .iov_len = bytes.len,
                .iov_base = bytes.ptr,
            }
        };
    }

    pub fn getBytes(self: @This()) []u8 {
        // rust would be screaming right now ;-)
        @intToPtr([*]u8, @ptrToInt(self.inner.iov_base))[0..self.inner.iov_len];
    }
};

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
