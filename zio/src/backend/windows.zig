const zio = @import("../../zio.zig");

pub fn initialize() zio.InitError!void {
    
}

pub fn cleanup() void {
    
}

pub const Handle = ;

pub const Buffer = struct {
    inner: ,

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This() {
            .inner = 
        };
    }

    pub fn getBytes(self: @This()) []u8 {
        
    }
};

pub const Ipv4 = struct {
    inner: ,

    pub fn from(address: u32, port: u16) @This() {
        return @This() {
            .inner = 
        };
    }
};

pub const Ipv6 = struct {
    inner: ,

    pub fn from(address: u128, port: u16, flow: u32, scope: u32) @This() {
        return @This() {
            .inner = 
        };
    }
};

pub const Event = struct {
    inner: ,

    pub fn getResult(self: @This()) zio.Result {
        
    }

    pub fn getData(self: @This(), poller: *Poller) usize {
        
    }
};

pub const Poller = struct {
    pub inline fn init(self: *@This()) InitError!void {
        
    }

    pub inline fn close(self: *@This()) void {
        
    }

    pub inline fn getHandle(self: @This()) zio.Handle {
        
    }

    pub inline fn fromHandle(handle: zio.Handle) @This() {
        
    }

    pub inline fn register(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Poller.RegisterError!void {
        
    }

    pub inline fn reregister(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Poller.RegisterError!void {
        
    }

    pub inline fn send(self: *@This(), data: usize) zio.Poller.SendError!void {
        
    }

    pub inline fn poll(self: *@This(), events: []Event, timeout: ?u32) zio.Poller.PollError![]Event {
        
    }
};

pub const Socket = struct {

    pub inline fn init(self: *@This(), flags: u8) zio.Socket.InitError!void {
        
    }

    pub inline fn close(self: *@This()) void {
        
    }

    pub inline fn getHandle(self: @This()) zio.Handle {
        
    }

    pub inline fn fromHandle(handle: zio.Handle) @This() {
        
    }

    pub inline fn isReadable(self: *const @This(), event: zio.Event) bool {
        
    }

    pub inline fn isWriteable(self: *const @This(), event: zio.Event) bool {
        
    }

    pub inline fn setOption(option: Option) zio.Socket.OptionError!void {
       
    }

    pub inline fn getOption(option: *Option) zio.Socket.OptionError!void {
        
    }

    pub inline fn bind(self: *@This(), address: *const zio.Address) zio.Socket.BindError!void {
        
    }

    pub inline fn listen(self: *@This(), backlog: u16) zio.Socket.ListenError!void {
        
    }

    pub inline fn connect(self: *@This(), address: *const zio.Address) zio.Result {
        
    }

    pub inline fn accept(self: *@This(), client: *zio.Handle, address: *zio.Address) zio.Result {
        
    }

    pub inline fn recv(self: *@This(), address: ?*zio.Address, buffers: []zio.Buffer) zio.Result {
        
    }

    pub inline fn send(self: *@This(), address: ?*const zio.Address, buffers: []const zio.Buffer) zio.Result {
        
    }
};
