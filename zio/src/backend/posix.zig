const std = @import("std");
const builtin = @import("builtin");
const zio = @import("../../zio.zig");

const os = std.os;
const system = os.system;

/// Needs to possibly return an error for the return type :/
var dummy_var: u8 = 0;
pub fn initialize() zio.InitError!void {
    if (@ptrCast(*volatile u8, &dummy_var).* != 0)
        return zio.InitError.InvalidState;
}

pub fn cleanup() void {
    // nothing to clean up
}

pub const Handle = i32;

pub const Buffer = struct {
    inner: os.iovec_const,

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This() {
            .inner = os.iovec_const {
                .iov_base = bytes.ptr,
                .iov_len = bytes.len,
            }
        };
    }

    pub fn getBytes(self: @This()) []u8 {
        return self.inner.iov_base[0..self.inner.iov_len];
    }
};

/// Linux doesnt need any dumb padding or Incoming buffer at all
pub const IncomingPadding = 0;

pub const Ipv4 = packed struct {
    inner: os.sockaddr_in,

    pub fn from(address: u32, port: u16) @This() {
        return @This() {
            .inner = os.sockaddr_in {
                .sin_family = os.AF_INET,
                .sin_port = std.mem.nativeToBig(@typeOf(port), port),
                .sin_zero = [_]u8{0} * @sizeOf(@typeOf(os.sockaddr_in(undefined).sin_zero)),
                .sin_addr = os.in_addr { .s_addr = std.mem.nativeToBig(@typeOf(address), address) },
            }
        };
    }
};

pub const Ipv6 = packed struct {
    inner: os.sockaddr_in6,

    pub fn from(address: u128, port: u16, flow: u32, scope: u32) @This() {
        return @This() {
            .inner = os.sockaddr_in6 {
                .sin6_family = os.AF_INET6,
                .sin6_port = std.mem.nativeToBig(@typeOf(port), port),
                .sin6_flowinfo = std.mem.nativeToBig(@typeOf(flow), flow),
                .sin6_scope_id = std.mem.nativeToBig(@typeOf(scope), scope),
                .sin6_addr = os.in_addr6 { .Qword = std.mem.nativeToBig(@typeOf(address), address) },
            }
        };
    }
};

pub const Event = struct {
    inner: os.Kevent,

    pub fn getData(self: *@This(), poller: *Poller) usize {
        return self.inner.udata;
    }

    pub fn getResult(self: *@This()) zio.Result {
        
    }

    pub const Poller = struct {
        pub fn init(self: *@This()) zio.Event.Poller.InitError!void {
            
        }

        pub fn close(self: *@This()) void {
            
        }

        pub fn getHandle(self: @This()) zio.Handle {
            
        }

        pub fn fromHandle(handle: zio.Handle) @This() {
            
        }

        pub fn register(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            
        }

        pub fn reregister(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            
        }

        pub fn send(self: *@This(), data: usize) zio.Event.Poller.SendError!void {
            
        }

        pub fn poll(self: *@This(), events: []Event, timeout: ?u32) zio.Event.Poller.PollError![]Event {
            
        }
    };
};

pub const Socket = struct {

    pub fn init(self: *@This(), flags: u8) zio.Socket.InitError!void {
        
    }

    pub fn close(self: *@This()) void {
        
    }

    pub fn getHandle(self: @This()) zio.Handle {
        
    }

    pub fn fromHandle(handle: zio.Handle) @This() {
        
    }

    pub fn isReadable(self: *const @This(), event: Event) bool {
        
    }

    pub fn isWriteable(self: *const @This(), event: Event) bool {
        
    }

    pub fn setOption(option: Option) zio.Socket.OptionError!void {
       
    }

    pub fn getOption(option: *Option) zio.Socket.OptionError!void {
        
    }

    pub fn bind(self: *@This(), address: *const zio.Address) zio.Socket.BindError!void {
        
    }

    pub fn listen(self: *@This(), backlog: u16) zio.Socket.ListenError!void {
        
    }

    pub fn connect(self: *@This(), address: *const zio.Address) zio.Result {
        
    }

    pub fn accept(self: *@This(), incoming: *zio.Address.Incoming) zio.Result {
        
    }

    pub fn recv(self: *@This(), address: ?*zio.Address, buffers: []zio.Buffer) zio.Result {
        
    }

    pub fn send(self: *@This(), address: ?*const zio.Address, buffers: []const zio.Buffer) zio.Result {
        
    }
};