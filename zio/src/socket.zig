const zio = @import("../zio.zig");

/// A bi-directional stream of network data.
/// `Socket`s have two conceptual IO channels: Reader, Writer.
///     - `read()` and `accept()` lock the Reader channel
///     - `write()` and `connect()` lock the Writer channel
///     - `close()`, `bind()` and `listen()` lock both channels.
/// Once a channel is locked, no other operation which requires
/// that channel should be called in parallel unless its undefined behavior.
/// TODO: Maybe inforce this invariant at runtime using an error set?
///
/// IO operations, such as those listed above, return a `zio.Result`:
///     - `zio.Result.Status.Error`:
///         The operation was unable to complete.
///     - `zio.Result.Status.Retry`:
///         The operation would normally block.
///         This is only returned if the socket is non-blocking.
///         For sockets registered using `zio.Event.Poller.OneShot`,
///         this is when one should reregister the socket in order to listen for completion.
///         `zio.Result.data` contains bytes transferred if any.
///     - `zio.Result.Status.Partial`:
///         The operation completed, but only partially.
///         One should perform the operation again to consume more data.
///         At the moment, this is only returned on `.recv()` for
///         fragmented UDP packets but that may change in the future.
///         One can use `zio.errno(zio.Result.data)` for platform-specific info.
///     - `zio.Result.Status.Completed`:
///         The operation completed fully and successfully.
///         `zio.Result.data` contains bytes transferred if any.
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

    /// Initialize a socket using the given socket flags as a bitmask.
    /// Only one of Ipv4 and Ipv6 may be set unless InvalidValue is raised.
    /// Only one of Raw, Tcp and Udp may be set unless InvalidValue is raised.
    /// If `Nonblock` is set, IO operations will return `zio.Result.Retry`
    /// to indicate that the operation would normally block.
    pub inline fn init(self: *@This(), flags: u8) InitError!void {
        return self.inner.init(flags);
    }

    /// Close the socket, freeing its internal resources as well as:
    /// - cancel any pending non-blocking IO operations on all channels.
    /// - unregister it from any `zio.Event.Poller` instances if registered.
    pub inline fn close(self: *@This()) void {
        return self.inner.close();
    }

    /// Get the internal `Handle` for the socket
    pub inline fn getHandle(self: @This()) zio.Handle {
        return self.inner.getHandle();
    }

    /// Create a socket from a given `Handle`.
    /// This should not be called from a `Socket` handle
    /// in the middle of a non-blocking IO operation.
    pub inline fn fromHandle(handle: zio.Handle) @This() {
        return @This() { .inner = zio.backend.Socket.fromHandle(handle) };
    }

    /// Check if an `Event` produced by an IO operation
    /// on this socket originated from the Reader channel.
    pub inline fn isReadable(self: *const @This(), event: zio.Event) bool {
        return self.inner.isReadable(event.inner);
    }

    /// Check if an `Event` produced by an IO operation
    /// on this socket originated from the Writeable channel.
    pub inline fn isWriteable(self: *const @This(), event: zio.Event) bool {
        return self.inner.isWriteable(event.inner);
    }

    pub const OptionError = error {
        // TODO
    };

    pub const Option = union(enum) {
        ReuseAddr: bool,
        // TODO
    };

    /// Given an option variant, set the desired option on the socket.
    pub inline fn setOption(option: Option) OptionError!void {
        return self.inner.setOption(option);
    }

    /// Get the option variant, storing the result in the argument if success.
    pub inline fn getOption(option: *Option) OptionError!void {
        return self.inner.getOption(option);
    }

    pub const BindError = error {
        // TODO
    };

    /// Bind the source address of the socket to the given `zio.Address`.
    /// Addresses bound can serve as servers for their instantiated protocol.
    pub inline fn bind(self: *@This(), address: usize, len: usize) BindError!void {
        return self.inner.bind(address);
    }

    pub const ListenError = error {
        // TODO
    };

    /// Convert the socket into passive mode in which it can
    /// receive connections (asynchronously) using `accept()`.
    /// `backlog` refers to the maximum depth of the accepted connection queue.
    pub inline fn listen(self: *@This(), backlog: u16) ListenError!void {
        return self.inner.listen(backlog);
    }

    /// Accept an incoming client from the current server.
    /// If it returns `zio.Result.Status.Retry` and is non-blocking
    /// One should ensure that the pointer to `incoming` remain live
    /// and untouched until the operation completes (usually via `zio.Event`).
    pub inline fn accept(self: *@This(), incoming: *zio.Address.Incoming) zio.Result {
        return self.inner.accept(incoming);
    }

    /// Connect to an address under the instantiated protocol.
    pub inline fn connect(self: *@This(), address: *const zio.Address) zio.Result {
        return self.inner.connect(address);
    }

    /// Receive incoming data from the socket into the given `zio.Buffers`.
    /// If `address` is not null, then it acts as a call to `recvfrom()` in C.
    /// This operation can complete partially but the `zio.Result.Status` reflects differently:
    ///     - `zio.Result.Status.Partial`: fragmented protocol packet. Call again to consume remaining data.
    ///     - `zio.Result.Status.Completed`: read some (may not be all) bytes into the `buffers` array.
    ///         The amount of bytes received can be retrieved from `zio.Result.data`.
    pub inline fn recv(self: *@This(), address: ?*zio.Address, buffers: []zio.Buffer) zio.Result {
        return self.inner.recv(address, @ptrCast([*]zio.backend.Buffer, buffers.ptr)[0..buffers.len]);
    }

    /// Send outgoing data from the socket using the given `zio.Buffers`.
    /// If `address` is not null, then it acts as a call to `sendto()` in C.
    /// Ths operation does not return `zio.Result.Status.Partial` like `recv()` but may not send all data.
    /// The amount of bytes sent on `zio.Result.Status.Completed` can be retrieved from `zio.Result.data`.
    pub inline fn send(self: *@This(), address: ?*const zio.Address, buffers: []const zio.Buffer) zio.Result {
        return self.inner.send(address, @ptrCast([*]const zio.backend.Buffer, buffers.ptr)[0..buffers.len]);
    }
};