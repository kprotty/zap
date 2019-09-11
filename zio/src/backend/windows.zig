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

    pub fn getData(self: @This(), poller: *Poller) usize {
        
    }

    pub fn getResult(self: @This()) zio.Result {
        
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

    pub fn accept(self: *@This(), client: *zio.Handle, address: *zio.Address) zio.Result {
        
    }

    pub fn recv(self: *@This(), address: ?*zio.Address, buffers: []zio.Buffer) zio.Result {
        
    }

    pub fn send(self: *@This(), address: ?*const zio.Address, buffers: []const zio.Buffer) zio.Result {
        
    }
};
