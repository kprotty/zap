const std = @import("std");
const builtin = @import("builtin");

pub const backend = switch (builtin.os) {
    .linux => @import("src/backend/linux.zig"),
    .windows => @import("src/backend/windows.zig"),
    /// only BSD systems since uses kqueue(). Will not be implementing poll() or select()
    .macosx, .freebsd, .netbsd, .openbsd, .dragonfly => @import("src/backend/posix.zig"),
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
/// - the side effects of the operation
/// - the actions to perform next in order to complete it
pub const Result = struct {
    data: u32,
    status: Status,

    pub const Status = enum {
        /// There was an error performing the operation.
        /// `data` refers to whatever work was completed nonetheless.
        Error,
        /// The operation was partially completed and would normally block.
        /// `data` refers to whatever work was partially completed.
        Retry,
        /// The operation was fully completed and `data` holds the result.
        Completed,
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


/// A bi-directional network stream
pub const Socket = @import("src/socket.zig").Socket;
/// A ipv4 or ipv6 network address
pub const Address = @import("src/address.zig").Address;
/// A selector to poll for IO events
pub const EventPoller = @import("src/poll.zig").EventPoller;
