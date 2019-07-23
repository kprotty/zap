const builtin = @import("builtin");

const Impl = switch (builtin.os) {
    .linux => @import("epoll.zig"),
    .windows => @import("iocp.zig"),
    .macosx, .freebsd, .netbsd => @import("kqueue.zig"),
    else => @compileError("Operating system not supported"),
};

pub const Handle = Impl.Handle;

pub const Selector = struct {
    inner: Impl.Selector,

    /// Get the internal OS Handle
    pub inline fn getHandle(self: Selector) Handle {
        return self.inner.getHandle();
    }

    /// Type of IO event to register for polling.
    /// Used in `register` to asynchronously wait for an event to complete/trigger.
    pub const Interest = enum {
        /// Listen for input events
        Read,
        /// Listen for output events
        Write,
        /// Listen for both input and output events
        ReadWrite,
    };

    pub const Token = packed struct {
        inner: Impl.Selector.Token,

        // If tokens are valid to use on the current platform
        pub const is_valid = Impl.Selector.Token.is_valid;

        pub inline fn getResult(self: Token) IOResult {
            return self.inner.getResult();
        }
    };

    pub const Event = packed struct {
        inner: Impl.Selector.Event,

        pub inline fn getToken(self: Event) ?*Token {
            return inner.getToken();
        }
        
        pub inline fn getUserData(self: Event) usize {
            return inner.getUserData();
        }        
    };

    pub inline fn new(num_threads: usize) ?Selector {
        const inner = Impl.Selector.new(num_threads) orelse return null;
        return Selector { .inner = inner };
    }

    pub inline fn register(self: *Selector, socket: *Socket, interest: Interest, user_data: usize) ?void {
        return self.inner.register(socket, interest, user_data);
    }

    pub inline fn unregister(self: *Selector, socket: *Socket) ?void {
        return self.inner.unregister(self, socket);
    }

    pub inline fn poll(self: *Selector, events: []Event, timeout_ms: ?u32) ?[]Event {
        return self.inner.poll(events, timeout_ms);
    }
};

pub const IOResult = union(enum) {
    TooLarge,
    Error: u32,
    Transferred: u32,
    RegisterRead: u32,
    RegisterWrite: u32,
};

pub const Buffer = struct {
    inner: Impl.Buffer,

    pub inline fn fromSlice(bytes: []u8) Buffer {
        return self.inner.fromSlice(bytes);
    }

    pub inline fn fromSliceConst(bytes: []const u8) Buffer {
        return self.inner.fromSliceConst(bytes);
    }

    pub inline fn toSlice(self: *Buffer) []u8 {
        return self.inner.to(bytes);
    }

    pub inline fn toSliceConst(self: *const Buffer) []const u8 {
        return self.inner.toSliceConst(bytes);
    }
};

pub const Socket = struct {
    inner: Impl.Socket,

    /// Get the internal OS Handle
    pub inline fn getHandle(self: Selector) Handle {
        return self.inner.getHandle();
    }

    /// Socket address family
    pub const Family = enum {
        Ipv4,
        Ipv6,
    };

    /// Socket protocol type
    pub const Protocol = enum {
        Raw,
        Tcp,
        Udp,
    };

    /// Create a new socket using a socket family, type and selector.
    ///  `family` represents AF_* property being the address family
    ///  `protocol` represents SOCK_* property being the type/protocol
    ///  `selector` if non null, creates a non blocking socket 
    pub inline fn new(
        family: Family,
        protocol: Protocol,
        selector: ?*Selector,
    ) ?Socket {
        return self.inner.new(family, protocol, selector);
    }

    /// Read from the socket into a slice of buffers
    ///  `buffers` internal representation of a [][]u8 to read into
    ///  `address` if non null, read in address as well via a recvfrom() equivalent
    ///  `token` if null, perform the operation synchronously. See more about tokens above
    /// returns `IOResult` so actions in response to it should be taken accordingly (See above)
    pub inline fn read(
        self: *Socket,
        buffers: []Buffer,
        address: ?*Address,
        token: ?*Token,
    ) IOResult {
        return self.inner.read(buffers, address, token);
    }

    /// Write into the socket using a slice of buffers
    ///  `buffers` internal representation of a [][]const u8 to write with
    ///  `address` if non null, send the address as well via a sendto() equivalent
    ///  `token` if null, perform the operation synchronously. See more about tokens above.
    /// returns `IOResult` so actions in response to it should be taken accordingly (See above)
    pub inline fn write(
        self: *Socket,
        buffers: []const Buffer,
        address: ?Address,
        token: ?*Token,
    ) IOResult {
        return self.inner.write(buffers, address, token);
    }

    /// Connect to a given address from a Protocol.Tcp socket.
    ///  `address` the address the attempt a connection with
    ///  `token` if null, perform the operation synchronously. See more about tokens above.
    /// returns `IOResult` with `Transferred` meaning successful connection (See more above).
    pub inline fn connect(
        self: *Socket,
        address: Address,
        token: ?*Token,
    ) IOResult {
        return self.inner.connect(address, token);
    }

    /// Accept an incoming client socket using the current Protocol.Tcp socket.
    ///  `address` the remote address of the client once accepted
    ///  `incoming` address to store the incoming socket once accepted (cannot be bind()'ed or connect()'ed)
    ///  `token` if null, perform the operation synchronously. See more about tokens above.
    /// returns `IOResult` with `Transferred` meaning successful acception (See more above).
    pub inline fn accept(
        self: *Socket,
        address: *Address,
        incoming: *Socket,
        token: ?*Token,
    ) IOResult {
        return self.inner.accept(self, address, incoming, token);
    }

    /// Transfer bytes from an OS handle to the socket without using an intermediary buffer.
    ///  `handle` the raw OS handle to internally read from
    ///  `transfer` amount of bytes to transfer
    ///  `token` if null, perform the operation synchronously. See more about tokens above.
    /// returns `IOResult` so actions in response to it should be taken accordingly (See above)
    pub inline fn sendfile(
        self: *Socket,
        handle: Handle,
        transfer: u32,
        token: ?*Token,
    ) IOResult {
        return self.inner.sendfile(self, handle, transfer, token);
    }

    /// Try and bind the socket to a given address.
    ///   `reuse_address` is akin to SO_REUSEADDR and possibly SO_REUSEPORT.
    /// See here for more information: https://stackoverflow.com/a/14388707
    pub inline fn bind(self: *Socket, address: *Address, reuse_address: bool) ?void {
        return self.inner.bind(address, reuse_address);
    }

    /// Set the socket into passive mode which listens for incoming connections.
    ///   `backlog` being max queue length of pending incoming connections. 
    pub inline fn listen(self: *Socket, backlog: u32) ?void {
        return self.inner.listen(backlog);
    }

    pub inline fn close(self: *Socket) void {
        return self.inner.close();
    }

    pub inline fn timeout(self: *Socket, ms: ?u32) u32 {
        return self.inner.timeout(ms);
    }

    pub inline fn keepAlive(self: *Socket, value: ?u32) u32 {
        return self.inner.keepAlive(value);
    }

    pub inline fn noDelay(self: *Socket, enabled: ?bool) bool {
        return self.inner.noDelay(enabled);
    }

    pub inline fn blocking(self: *Socket, enabled: ?bool) bool {
        return self.inner.blocking(enabled);
    }

    pub inline fn option(self: *Socket, level: u32, name: u32, value: ?[]u8) u32 {
        return self.inner.option(level, name, value);
    }

    /// Representing an interpret protocol address with a port number.
    /// Used to specify what machine to connect to on a given socket.
    pub const Address = packed struct {
        inner: Impl.Address,

        /// Create a new Ipv4 address structure
        pub inline fn v4(addr: u32, port: u16) Address {
            return Address { .inner = Impl.Address.v4(addr, port) };
        }

        /// Create a new Ipv6 address structure
        pub inline fn v6(addr: u128, port: u16) Address {
            return Address { .inner = Impl.Address.v6(addr, port) };
        }

        /// Get the address port
        pub inline fn getPort(self: Address) u16 {
            return self.inner.getPort();
        }

        /// Get the address ipv4 bitwise representation
        pub inline fn getIpv4(self: Address) u32 {
            return self.inner.getIpv4();
        }

        /// Get the address ipv6 bitwise representation
        pub inline fn getIpv6(self: Address) u128 {
            return self.inner.getIpv6();
        }

        /// Parse an ipv4 string into its bitwise representation
        pub fn parseIpv4(input: []const u8) ?u32 {
            
        }

        /// Parse an ipv6 string into its bitwise representation
        pub fn parseIpv6(input: []const u8) ?u128 {
            
        }
    };
};

