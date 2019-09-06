const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os) {
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    /// only BSD systems since uses kqueue(). Will not be implementing poll() or select()
    .macosx, .freebsd, .netbsd, .openbsd, .dragonfly => @import("posix.zig"),
    else => @compileError("Platform not supported"),
};

pub const InitError = std.os.UnexpectedError || error {
    /// Failed to load an IO function
    InvalidIOFunction,
    /// An internal system invariant was incorrect
    InvalidSystemState,
};

/// Allows the IO backend to initialize itself.
/// On windows, this loads functions + initializes WinSock2
pub inline fn Initialize() InitError!void {
    return backend.Initialize();
}

/// Allows the IO backend to clean up whatever it needs to.
pub inline fn Cleanup() void {
    return backend.Cleanup();
}

/// A handle represents a kernel resource object used to perform IO.
/// Other wrapper objects like `EventPollers`, `Sockets`, etc. can be created from / provide it.
pub const Handle = backend.Handle;

/// The result of an IO operation which denotes:
/// - the noted side-effects
/// - what action to take next.
pub const Result = struct {
    status: Status,
    transferred: usize,

    pub const Status = enum {
        /// The operation was fully completed successfully.
        /// The result of the operation lies in `transferred`. 
        Completed,
        /// There was an error performing the IO operation.
        /// One should `.close()` the resource object in question
        /// and no longer interact with it as that is then undefined.
        /// `transferred` represents the bytes transferred nonetheless 
        Error,
        /// The operation which produced this result should be retried.
        /// `transferred` instead refers to a hint which can be used for
        /// retrying the IO operation (e.g. bytes ready after a `.read()`)
        Retry,
        /// The operation completed partially, as in there is still more work to do.
        /// One should register/have registered the resource object under an `EventPoller`
        /// or use some other mechanism to wait for the kernel to allow the IO operation to progress.
        Partial,
    };
};

/// A Buffer represents a slice of bytes encoded in a form
/// which can be passed into IO operations for resource objects.
/// NOTE: At the moment, @sizeOf(Buffer) == @sizeOf([]u8) just the fields may be rearraged.
pub const Buffer = packed struct {
    inner: backend.Buffer,

    /// Convert a slice of bytes into a `Buffer`.
    /// Slices over std.math.maxInt(u32) may be truncated based on the platform
    pub inline fn fromBytes(bytes: []const u8) @This() {
        return self.inner.fromBytes(bytes);
    }

    /// Convert a `Buffer` back into a slice of bytes
    pub inline fn getBytes(self: @This()) []u8 {
        return self.inner.getBytes();
    }
};

/// An EventPoller is used to listen to & generate IO events for non-blocking resource objects.
pub const EventPoller = struct {
    inner: backend.EventPoller,

    /// Get the underlying Handle for this resource object
    pub inline fn getHandle(self: @This()) Handle {
        return self.inner.getHandle();
    }

    /// Create an `EventPoller` from a Handle.
    /// There should not exist more than one EventPoller active at a given point.
    /// It is also undefined behavior to call this method after previously calling `notify()` 
    pub inline fn fromHandle(handle: Handle) @This() {
        return self.inner.fromhandle(handle);
    }

    pub const Error = std.os.UnexpectedError || error {
        InvalidHandle,
    };

    /// Initialize the EventPoller
    pub inline fn init(self: *@This()) Error!void {
        return self.inner.init();
    }

    /// Close this resource object
    pub inline fn close(self: *@This()) void {
        return self.inner.close();
    }

    pub const READ:         u32 = 1 << 0;
    pub const WRITE:        u32 = 1 << 1;
    pub const ONE_SHOT:     u32 = 1 << 2;
    pub const EDGE_TRIGGER: u32 = 1 << 3;

    pub const RegisterError = Error || error {
        // TODO
    };

    /// In order for the `EventPoller` to receive IO events,
    /// one should register the IO resource object under the event poller.
    /// `data`: arbitrary user data which can be retrieved when polling for events.
    /// `flags`: it a bitmask of IO events to listen for and how:
    ///     - READ: an event will be generated once the resource object is readable.
    ///     - WRITE: an event will be generated onec the resource object is writeable.
    ///     - ONE_SHOT: once an event is consumed, it will no longer be generated and can be re-registered.
    ///     - EDGE_TRIGGER(defualt): once an event is consumed, it can be regenerated after the corresponding operation completes
    pub inline fn register(self: *@This(), handle: Handle, flags: u32, data: usize) RegisterError!void {
        return self.inner.register(handle, flags, data);
    }

    /// Similar to `register()` but should be called to re-register an event 
    /// if the handle was previously registerd with `ONE_SHOT`.
    /// This is most noteably called after a `Result.Status.Partial` operation registered with `ONE_SHOT`.
    pub inline fn reregister(self: *@This(), handle: Handle, flags: u32, data: usize) RegisterError!void {
        return self.inner.reregister(handle, flags, data);
    }

    pub const NotifyError = Error || error {
        // TODO
    };

    /// Generate a user-based event with the `data` being arbitrary user data.
    /// Most noteably used for communicating with an `EventPoller` which is blocked polling.
    /// `Event`s originating from a `notify()` call are always Readable and never Writeable.
    pub inline fn notify(self: *@This(), data: usize) NotifyError!void {
        return self.inner.notify(data);
    }

    /// A notification of an IO operation status - a.k.a. an IO event.
    pub const Event = packed struct {
        inner: backend.EventPoller.Event,

        /// Get the arbitrary user data tagged to the event when registering
        pub inline fn getData(self: @This()) usize {
            return self.inner.getData();
        }

        /// Get the result of the corresponding IO operation to continue processing
        pub inline fn getResult(self: @This()) Result {
            return self.inner.getResult();
        }

        /// Get an identifier which can be used (e.g. by `Socket.isReadable()`) 
        /// to know which pipe the event originated from in order to help event processing.
        pub inline fn getIdentifier(self: @This()) usize {
            return self.inner.getIdentifier();
        }
    };

    pub const PollError = Error || error {
        // TODO
    };

    /// Poll for `Event` objects that have been ready'd by the kernel.
    /// `timeout`: amount of milliseconds to block until one or more events are ready'd.
    ///     - if `timeout` is null, then poll() will block indefinitely until an event is ready'd
    ///     - if `timeout` is 0, then poll() will return with any events that were immediately ready'd (can be empty)
    pub inline fn poll(self: *@This(), events: []Event, timeout: ?u32) PollError![]Event {
        return self.inner.poll(events, timeout);
    }
};

/// A bi-directional stream for communicating over networks.
/// `Socket` object consists of two conceptual pipes/channels for IO operations: READ, WRITE.
/// IO operations which LOCK a pipe mean that they should be the only thread performing IO on that pipe.
/// It is safe to be performing two IO operations in parallel as long as they do not both LOCK the same pipe.
pub const Socket = struct {
    inner: backend.Socket,

    /// Get the underlying Handle for this resource object
    pub inline fn getHandle(self: @This()) Handle {
        return self.inner.getHandle();
    }

    /// Create a `Socket` from a Handle.
    /// There should not exist more than one EventPoller active at a given point.
    pub inline fn fromHandle(handle: Handle) @This() {
        return self.inner.fromhandle(handle);
    }

    pub const Raw:      u32 = 1 << 0;
    pub const Tcp:      u32 = 1 << 1;
    pub const Udp:      u32 = 1 << 2;
    pub const Ipv4:     u32 = 1 << 3;
    pub const Ipv6:     u32 = 1 << 4;
    pub const Nonblock: u32 = 1 << 5;

    pub const Error = error {
        // TODO
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

    /// Use the result of `EventPoller.Event.getIdenfier()` to discover if the event is from the READ pipe.
    pub inline fn isReadable(self: *@This(), identifier: usize) bool {
        return self.inner.isReadable(identifier);
    }

    /// Use the result of `EventPoller.Event.getIdenfier()` to discover if the event is from the WRITE pipe.
    pub inline fn isWriteable(self: *@This(), identifier: usize) bool {
        return self.inner.isWriteable(identifier);
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
    pub inline fn read(self: *@This(), buffers: []Buffer) Result {
        return self.inner.read(buffers);
    }

    /// IO:[LOCKS READ PIPE] Write data to the underlying socket using the buffers.
    /// `Result.transferred` represents the amount of bytes written to the socket.
    /// if `Result.Status.Partial` and `EventPoller.ONE_SHOT`, re-register using `EventPoller.WRITE`.
    pub inline fn write(self: *@This(), buffers: []const Buffer) Result {
        return self.inner.write(buffers);
    }

    pub const Address = union(enum) {
        v4: backend.Socket.Ipv4,
        v6: backend.Socket.Ipv6,

        pub fn parseIpv4(address: []const u8, port: u16) ?@This() {
            // var addr: u32 = // TODO: ipv4 parsing
            return @This() { .v4 = backend.Socket.Ipv4.from(addr, port) };
        }

        pub fn parseIpv6(address: []const u8, port: u16) ?@This() {
            // var addr: u128 = // TODO: ipv6 parsing
            return @This() { .v6 = backend.Socket.Ipv6.from(addr, port) };
        }

        pub fn writeTo(self: @This(), buffer: []u8) ?void {
            // TODO: ipv4 & ipv6 serialization
            return null;
        }
    };

    pub const BindError = ListenError || error {
        // TODO
    };

    /// [LOCKS READ & WRITE PIPE] Bind and set the source address for the underlying socket object.
    /// Should be called before doing any other IO operation if necessary.
    /// Will block until completion even on `Socket.Nonblock`.
    pub inline fn bind(self: *@This(), address: *Address) BindError!void {
        return self.inner.bind(address);
    }

    pub const ListenError = error {
        // TODO
    };

    /// [LOCKS READ & WRITE PIPE] Marks the socket as passive to be used for `accept()`ing connections.
    /// `backlog` sets the max size of the queue for pending connections.
    pub inline fn listen(self: *@This(), backlog: u16) ListenError!void {
        return self.inner.listen(backlog);
    }

    /// IO:[LOCKS READ PIPE] Accept an incoming connection from the socket.
    /// The peer address of the client is stored in the given `address` pointer.
    /// The client Handle can be @intCast()'ed from `Result.transffered` if `Result.Status.Completed`.
    /// The client Handle can then be used to create a client socket using `Socket.fromHandle()`.
    /// if `Result.Status.Partial` and `EventPoller.ONE_SHOT`, re-register using `EventPoller.READ`.
    pub inline fn accept(self: *@This(), address: *Address) Result {
        return self.inner.accept(address, client);
    }

    /// IO:[LOCKS WRITE PIPE] Starts a (TCP) connection with a remote address using the socket.
    /// if `Result.Status.Completed`, then the connection was completed and it is safe to call `read()` and `write()`
    /// if `Result.Status.Partial` and `EventPoller.ONE_SHOT`, re-register using `EventPoller.WRITE`.
    pub inline fn connect(self: *@This(), address: *Address) Result {
        return self.inner.connect(address);
    }
};
