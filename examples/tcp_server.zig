const std = @import("std");
const zio = @import("zio.zig");

fn tcp_server() !void {
    // initialize the socket api
    _ = zio.Socket.init();
    defer zio.Socket.deinit();

    // create a new tcp socket
    const socket = zio.Socket.new(
        zio.Socket.Family.Ipv4,
        zio.Socket.Protocol.Tcp,
        null,
    ) orelse return error.SocketError;
    defer socket.close();

    // bind the socket to 127.0.0.1:12345
    const local = zio.Socket.Address.parseIpv4("127.0.0.1");
    const address = zio.Socket.Address.v4(local, 12345);
    _ = socket.bind(address, true) orelse return error.SocketBind;
    _ = socket.listen(128) orelse return error.SocketListen;

    // accept an incoming socket for the client
    var client_sock: zio.Socket = undefined;
    var client_addr: zio.Socket.Address = undefined;
    _ = socket.accept(&client_addr, &client_sock, null) orelse return error.SocketAccept;
    defer client_sock.close();

    // prepare 1024 bytes
    var input: [1024]u8 = undefined;
    var buffers = [_]zio.Buffer { zio.Buffer.fromSlice(input[0..]) };
    
    // read those bytes from the client
    const bytes_received = switch (client_sock.read(buffers, null, null)) {
        .Error => return error.SocketRead,
        .Transferred |received| => received,
        .RegisterRead, .RegisterWrite => unreachable, // not in async mode
        .Retry => unreachable, // byte size of sum(buffers) < std.math.maxInt(u32) and not in async mode
    };

    // write those bytes back to the client
    buffers[0] = zio.Buffer.fromSlice(input[0..bytes_received]);
    switch (client_sock.write(buffers, null, null)) {
        .Error => return error.SocketWrite,
        .Transferred |bytes_sent| => std.debug.assert(bytes_sent == bytes_received),
        else => unreachable,
    }
}

fn async_tcp_server() !void {
    // async socket client and allocator
    const allocator = std.heap.direct_allocator;
    const AsyncClient = ClientSocket {
        const CLRF = "\r\n\r\n"; // appended to every write (hence [2] for wrapped)
        
        // socket information
        server: *AsyncServer,
        prev: ?*AsyncClient,
        next: ?*AsyncClient,
        socket: zio.Socket,
        token: zio.Token,
        interest: zio.Selector.Event.Interest,
        
        // address identifiers
        address: ?[]u8,
        port: u16,

        // IO buffers
        offset: u32,
        buffer: [1024]u8,
        wrapped: [2][]zio.Buffer,

        pub fn init(
            next: ?*AsyncClient,
            socket: zio.Socket,
            address: zio.Socket.Address,
            selector: *zio.Selector,
        ) !void {
            // initialize the socket
            self.offset = 0;
            self.address = null;
            self.socket = socket;
            self.port = address.getPort();

            // get and print out the peer address
            const addr_str = try allocator.alloc(u8, address.writeTo(null));
            self.address = addr_str[0..addres.writeTo(self.address)];
            std.debug.warn("{}:{} connected\n", addr_str, self.port);
            
            // start echoing data
            self.interest = zio.Selector.Event.Interest.Read;
            return self.handle_result(self.perform_io(), selector);
        }

        // free memory allocated on heap and close the socket
        pub fn deinit(self: *AsyncClient) {
            // free socket info
            if (self.address) |addr_str|
                _ = allocator.free(addr_str);
            _ = self.socket.close();
            
            // free client from server
            if (self.next) |next| 
                next.prev = self.prev;
            if (self.prev) |prev|
                prev.next = self.next;
            if (self.server.head == self)
                self.server.head = self.next;
            if (self.server.tail == self)
                self.server.tail = slf.next;
            _ = allocator.destroy(self);
        }

        // shorthand to register socket
        inline fn register(
            self: *AsyncServer,
            selector: *zio.Selector,
            interest: zio.Selector.Event.Interest,
        ) !void {
            self.interest = interest;
            return selector.register(
                self.socket.getHandle(),
                interest,
                @ptrToInt(self),
            );
        }

        // handle incoming selector events
        pub fn handle_event(
            self: *AsyncServer,
            selector: *zio.Selector,
            event: zio.Selector.Event,
        ) !void {
            // Small check to ensure we have the right event by checking token authenticity
            std.debug.assert(event.getToken().is(switch (self.interest) {
                .Write => self.token.asWriter(),
                .Read => self.token.asReader(),
                else => &self.token,
            }));

            // Get IO result and handle the it
            var result = event.getResult();
            return self.handle_result(switch (result) {
                .Retry => self.perform_io(),
                else => result,
            }, selector);
        }

        // read from the socket and echo back to the socket with CLRF at the end
        fn perform_io(self: *AsyncClient) zio.Token.Result {
            _ = self.token.reset();
            return switch (self.interest) {
                .Read => result: {
                    self.wrapped[0] = zio.Buffer.fromSlice(self.buffer[self.offset..]);
                    break :result self.socket.read(self.wrapped[0..1], null, &self.token);
                },
                .Write => result: {
                    var wrapped_length = usize(1);
                    if (self.offset > self.buffer.len) {
                        self.wrapped[0] = zio.Buffer.fromSliceConst(CLRF[(self.buffer.len - self.offset)..]);
                    } else {
                        self.wrapped[0] = zio.Buffer.fromSliceConst(self.buffer[self.offset...]);
                        self.wrapped[1] = zio.Buffer.fromSliceConst(CLRF);
                        wrapped_length = 2;
                    }
                    break :result self.socket.write(self.wrapped[0..wrapped_len], null, &self.token);
                },
                else => unreachable,
            };
        }

        // handle the result of an IO operation
        fn handle_result(
            self: *AsyncClient,
            result: zio.Token.Result,
            selector: *zio.Selector,
        ) !void {
            var had_error = false;
            self.offset += switch (result) {
                // Buffers are more than small enough, shouldnt happen
                .Retry => unreachable,
                // successfully read/written, update offset
                .Transferred |bytes| => bytes,
                // had socket error or simply peer closed
                .Error |bytes| => value: {
                    had_error = true;
                    break :value bytes;
                },
                // transferred some bytes, but register for Read event to process the remaining
                .RegisterRead |bytes| => value: {
                    try self.register(selector, zio.Selector.Event.Interest.Read);
                    break :value bytes;
                },
                // transferred some bytes, but register for Write event to process the remaining
                .RegisterWrite |bytes| => value: {
                    try self.register(selector, zio.Selector.Event.Interest.Write);
                    break :value bytes;
                },
            };

            // Find the offset limit comparison and new_state to swap with if offset limit is reached
            var limit = self.buffer.len;
            var new_state = zio.Selector.Event.Interest.Write;
            if (self.interest == .Write) {
                limit += CLRF.len;
                new_state = zio.Selector.Event.Interest.Read;
            }

            // print out buffer if done reading
            if (self.interest == .Read and (self.offset >= limit or had_error)) {
                if (self.address) |addr_str|
                    std.debug.warn("{}:{}> {}\n\n", addr_str, self.port, self.buffer[0..self.offset]);
            }

            // Kill the client if had error or switch from reading -> writing or vice versa
            if (had_error) {
                return self.deinit();
            } else if (self.offset >= limit) {
                self.offset = 0;
                self.interest = new_state;
                return self.handle_result(self.perform_io(), selector);
            }
        }
    };

    // async socket structure
    const AsyncServer = struct {
        // socket information
        socket: zio.Socket,
        token: zio.Token,
        interest: zio.Selector.Event.Interest,

        // client accepting information
        client: zio.Socket,
        address: zio.Socket.Address,
        head: ?*AsyncClient,
        tail: ?*AsyncClient,

        // shorthand to register socket
        inline fn register(
            self: *AsyncServer,
            selector: *zio.Selector,
            interest: zio.Selector.Event.Interest,
        ) !void {
            self.interest = interest;
            return selector.register(
                self.socket.getHandle(),
                interest,
                @ptrToInt(self),
            );
        }

        // Try and accept a client
        pub fn accept(self: *AsyncServer, selector: *zio.Selector) !void {
            return self.handle_result(self.perform_accept(), selector);
        }

        // Close all server connections
        pub fn close(self: *AsyncServer) void {
            while (self.head) |client| {
                self.head = client.next;
                _ = client.deinit();
            }
            _ = self.socket.close();
        }

        // handle incoming selector events
        pub fn handle_event(
            self: *AsyncServer,
            selector: *zio.Selector,
            event: zio.Selector.Event,
        ) !void {
            // Small check to ensure we have the right event by checking token authenticity
            std.debug.assert(event.getToken().is(switch (self.interest) {
                .Write => self.token.asWriter(),
                .Read => self.token.asReader(),
                else => &self.token,
            }));

            // Get the accept IO result and handle it
            var result = event.getResult();
            self.handle_result(switch (result) {
                .Retry => self.perform_accept(),
                else => result,
            }, selector);
        }

         // handle the result of an Accept operation
        fn handle_result(
            self: *AsyncClient,
            result: zio.Token.Result,
            selector: *zio.Selector,
        ) !void {
            return switch (result) {
                // shouldnt happen since not transfering data
                .Retry => unreachable,
                // socket error
                .Error => error.ServerAccept,
                // wait for read event,
                .RegisterRead => self.register(selector, zio.Selector.Event.Interest.Read),
                // wait for write event,
                .RegisterWrite => self.register(selector, zio.Selector.Event.Interest.Write),
                // accepted client into self.client,
                .Transferred => {
                    var client = try allocator.create(AsyncClient);
                    client.next = null;
                    client.server = self;

                    // add client to server queue
                    if (self.tail orelse self.head) |node| {
                        node.next = client;
                        client.prev = node;
                        self.tail = client;
                    } else {
                        client.prev = null;
                        self.head = client;
                        self.tail = client;
                    }
                    
                    // Complete initialization then try and accept other clients
                    errdefer client.deinit();
                    _ = try client.init(self.client, self.address, selector);
                    return self.accept(); 
                },
            }
        }
    };

    // initialize the socket api
    _ = zio.Socket.init();
    defer zio.Socket.deinit();

    // create a new selector/event-poller with some events
    const selector = zio.Selector.new(0) orelse return error.SelectorError;
    defer selector.close();

    // create async server socket using selector
    var server: AsyncServer = undefined;
    server.socket = zio.Socket.new(
        zio.Socket.Family.Ipv4,
        zio.Socket.Protocol.Tcp,
        &selector,
    ) orelse return error.SocketError;
    server.head = null;
    server.tail = null;
    defer server.close();
    
    // bind the server to 127.0.0.1:12345
    const local = zio.Socket.Address.parseIpv4("127.0.0.1");
    const address = zio.Socket.Address.v4(local, 12345);
    _ = server.socket.bind(address, true) orelse return error.SocketBind;
    _ = server.socket.listen(128) orelse return error.SocketListen;
    try server.register();

    // start accepting clients
    try server.accept();

    // handle events
    var events: [64]zio.Selector.Event = undefined;
    while (true) {
        for (selector.poll(events[0..], null) orelse return error.SelectorPoll) |event| {
            if (event.getUserData() == @ptrToInt(&server)) {
                try server.handle_event(&selector, event);
            } else {
                try @intToPtr(*AsyncClient, event.getUserData()).handle_event(&selector, event);
            }
        }
    }

}

