const zio = @import("../zio.zig");

/// A bi-directional stream for communicating over networks.
/// `Socket` object consists of two conceptual pipes/channels for IO operations: READ, WRITE.
/// IO operations which LOCK a pipe mean that they should be the only thread performing IO on that pipe.
/// It is safe to be performing two IO operations in parallel as long as they do not both LOCK the same pipe.
pub const Socket = struct {
    inner: zio.backend.Socket,

    pub const Raw:      u32 = 1 << 0;
    pub const Tcp:      u32 = 1 << 1;
    pub const Udp:      u32 = 1 << 2;
    pub const Ipv4:     u32 = 1 << 3;
    pub const Ipv6:     u32 = 1 << 4;
    pub const Nonblock: u32 = 1 << 5;

    /// Get the underlying Handle for this resource object
    pub inline fn getHandle(self: @This()) zio.Handle {
        return self.inner.getHandle();
    }

    /// Create a `Socket` from a Handle using `flags` as the context.
    /// There should not exist more than one EventPoller active at a given point.
    pub inline fn fromHandle(handle: zio.Handle, flags: u32) @This() {
        return self.inner.fromhandle(handle);
    }

    pub const Error = error {
        InvalidState,
        InvalidValue,
        OutOfResources,
    };

    /// Initialize a socket using the given flags.
    ///     - Ipv4 and Ipv6 are exclusively detected in that order
    ///     - Raw, Tcp, and Udp are exclusively detected in that order
    ///     - Nonblock makes all IO calls to return `Result.Status.Partial` if they were to block
    pub inline fn init(self: *@This(), flags: u32) Error!void {
        return self.inner.init(flags);
    }
    
    /// Close this resource object
    pub inline fn close(self: *@This()) void {
        return self.inner.close();
    }

    pub const Option = union(enum) {
        ReuseAddr: bool,
        TcpNoDelay: bool,
        ReadBufferSize: usize,
        WriteBufferSize: usize,
        // TODO: Others
    };

    pub const OptionError = error {
        // TODO
    };

    /// Set an option on the internal socket object in the kernel
    pub inline fn setOption(option: Option) OptionError!void {
        return self.inner.setOption(option);
    }

    /// Get an option from the internal socket object in the kernel
    pub inline fn getOption(option: *Option) OptionError!void {
        return self.inner.getOption(option);
    }

    /// IO:[LOCKS READ PIPE] Read data from the underlying socket into the buffers.
    /// `Result.transferred` represents the amount of bytes read from the socket.
    /// if `Result.Status.Partial` and `EventPoller.ONE_SHOT`, re-register using `EventPoller.READ`.
    pub inline fn read(self: *@This(), buffers: []zio.Buffer) zio.Result {
        return self.inner.read(buffers);
    }

    /// Similar to `read()` but works with message based protocols (Udp).
    /// Receives the address of the peer sender into 'address'.
    /// 'address' pointer must be live until it returns `Result.Status.Completed`.
    pub inline fn readFrom(self: *@This(), address: *zio.Address, buffers: []zio.Buffer) zio.Result {
        return self.inner.readFrom(address, buffers);
    }

    /// IO:[LOCKS READ PIPE] Write data to the underlying socket using the buffers.
    /// `Result.transferred` represents the amount of bytes written to the socket.
    /// if `Result.Status.Partial` and `EventPoller.ONE_SHOT`, re-register using `EventPoller.WRITE`.
    pub inline fn write(self: *@This(), buffers: []const zio.Buffer) Result {
        return self.inner.write(buffers);
    }

    /// Similar to `write()` but works with message based protocols (Udp).
    /// Send the data using the peer address of the 'address' pointer.
    /// 'address' pointer must be live until it returns `Result.Status.Completed.`
    pub inline fn writeTo(self: *@This(), address: *const zio.Address, buffers: []const zio.Buffer) zio.Result {
        return self.inner.writeTo(address, buffers);
    }

    pub const BindError = ListenError || error {
        AddressInUse,
        InvalidAddress,
    };

    /// [LOCKS READ & WRITE PIPE] Bind and set the source address for the underlying socket object.
    /// Should be called before doing any other IO operation if necessary.
    /// Will block until completion even on `Socket.Nonblock`.
    pub inline fn bind(self: *@This(), address: *Address) BindError!void {
        return self.inner.bind(address);
    }

    pub const ListenError = error {
        InvalidState,
        InvalidHandle,
        OutOfResources,
    };

    /// [LOCKS READ & WRITE PIPE] Marks the socket as passive to be used for `accept()`ing connections.
    /// `backlog` sets the max size of the queue for pending connections.
    pub inline fn listen(self: *@This(), backlog: u16) ListenError!void {
        return self.inner.listen(backlog);
    }

    /// IO:[LOCKS WRITE PIPE] Starts a (TCP) connection with a remote address using the socket.
    /// The `address` pointer needs to be live until `Result.Stats.Completed` is returned.
    /// if `Result.Status.Completed`, then the connection was completed and it is safe to call `read()` and `write()`
    /// if `Result.Status.Partial` and `EventPoller.ONE_SHOT`, re-register using `EventPoller.WRITE`.
    pub inline fn connect(self: *@This(), address: *zio.Address) zio.Result {
        return self.inner.connect(address);
    }

    /// IO:[LOCKS READ PIPE] Accept an incoming connection from the socket.
    /// The client's handle is stored in the given 'client' pointer.
    /// The peer address of the client is stored in the given `address` pointer.
    /// If `Nonblock`, both the `address` and the `client` pointers need to be live until `Result.Status.Completed`
    /// if `Result.Status.Partial` and `EventPoller.ONE_SHOT`, re-register using `EventPoller.READ`.
    pub inline fn accept(self: *@This(), client: *zio.Handle, address: *Address) zio.Result {
        return self.inner.accept(client, address);
    }
};

pub const Address = struct {
    length: c_int,
    address: IpAddress,

    const IpAddress = packed union {
        v4: zio.backend.Socket.Ipv4,
        v6: zio.backend.Socket.Ipv6,
    };

    pub fn parseIpv4(address: []const u8, port: u16) ?@This() {
        // var addr: u32 = // TODO: ipv4 parsing
        return @This() {
            .length = @sizeOf(zio.backend.Socket.Ipv4),
            .address = IpAddress {
                .v4 = zio.backend.Socket.Ipv4.from(addr, port),
            },
        };
    }

    pub fn parseIpv6(address: []const u8, port: u16) ?@This() {
        // var addr: u128 = // TODO: ipv6 parsing
        return @This() {
            .length = @sizeOf(zio.backend.Socket.Ipv6),
            .address = IpAddress {
                .v6 = zio.backend.Socket.Ipv6.from(addr, port),
            },
        };
    }

    pub fn writeTo(self: @This(), buffer: []u8) ?void {
        // TODO: ipv4 & ipv6 serialization
        return null;
    }
};