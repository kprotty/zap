const zio = @import("../zio.zig");

pub const Socket = struct {
    inner: zio.backend.Socket,

    pub const InitError = error {
        // TODO
    };

    pub const Raw = 1 << 0;
    pub const Tcp = 1 << 1;
    pub const Udp = 1 << 2;
    pub const Ipv4 = 1 << 3;
    pub const Ipv6 = 1 << 4;
    pub const Nonblock = 1 << 5;

    pub inline fn init(self: *@This(), flags: u8) InitError!void {
        return self.inner.init(flags);
    }

    pub inline fn close(self: *@This()) void {
        return self.inner.close();
    }

    pub inline fn getHandle(self: @This()) zio.Handle {
        return self.inner.getHandle();
    }

    pub inline fn fromHandle(handle: zio.Handle) @This() {
        return @This() { .inner = zio.backend.Socket.fromHandle(handle) };
    }

    pub inline fn isReadable(self: *const @This(), event: zio.Event) bool {
        return self.inner.isReadable(event);
    }

    pub inline fn isWriteable(self: *const @This(), event: zio.Event) bool {
        return self.inner.isWriteable(event);
    }

    pub const OptionError = error {
        // TODO
    };

    pub const Option = union(enum) {
        ReuseAddr: bool,
        // TODO
    };

    pub inline fn setOption(option: Option) OptionError!void {
        return self.inner.setOption(option);
    }

    pub inline fn getOption(option: *Option) OptionError!void {
        return self.inner.getOption(option);
    }

    pub const BindError = error {
        // TODO
    };

    pub inline fn bind(self: *@This(), address: *const zio.Address) BindError!void {
        return self.inner.bind(address);
    }

    pub const ListenError = error {
        // TODO
    };

    pub inline fn listen(self: *@This(), backlog: u16) ListenError!void {
        return self.inner.listen(backlog);
    }

    pub inline fn connect(self: *@This(), address: *const zio.Address) zio.Result {
        return self.inner.connect(address);
    }

    pub inline fn accept(self: *@This(), client: *zio.Handle, address: *zio.Address) zio.Result {
        return self.inner.accept(client, address);
    }

    pub inline fn recv(self: *@This(), address: ?*zio.Address, buffers: []zio.Buffer) zio.Result {
        return self.inner.recv(address, @ptrCast([*]zio.backend.Buffer, buffers.ptr)[0..buffers.len]);
    }

    pub inline fn send(self: *@This(), address: ?*const zio.Address, buffers: []const zio.Buffer) zio.Result {
        return self.inner.send(address, @ptrCast([*]const zio.backend.Buffer, buffers.ptr)[0..buffers.len]);
    }
};