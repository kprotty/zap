const zio = @import("../zio.zig");

pub const InitError = error {
    // TODO
};

pub inline fn initialize() InitError!void {
    return zio.backend.initialize();
}

pub inline fn cleanup() void {
    return zio.backend.cleanup();
}

pub const Handle = zio.backend.Handle;

pub const Result = struct {
    data: u32,
    status: Status,

    pub const Status = enum {
        Error,
        Retry,
        Partial,
        Completed,
    };
};

pub const Buffer = struct {
    inner: zio.backend.Buffer,

    pub inline fn fromBytes(bytes: []const u8) @This() {
        return @This() { .inner = zio.backend.Buffer.fromBytes(bytes) };
    }

    pub inline fn getBytes(self: @This()) []u8 {
        return self.inner.getBytes();
    }
};
