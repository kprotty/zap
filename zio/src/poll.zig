const zio = @import("../zio.zig");

pub const Event = struct {
    inner: zio.backend.Event,

    pub inline fn getResult(self: @This()) zio.Result {
        return self.inner.getResult();
    }

    pub inline fn getData(self: @This(), poller: *Poller) usize {
        return self.inner.getData(&poller.inner);
    }
};

pub const Poller = struct {
    inner: zio.backend.Poller,

    pub const InitError = error {
        // TODO
    };

    pub inline fn init(self: *@This()) InitError!void {
        return self.inner.init();
    }

    pub inline fn close(self: *@This()) void {
        return self.inner.close();
    }

    pub inline fn getHandle(self: @This()) zio.Handle {
        return self.inner.getHandle();
    }

    pub inline fn fromHandle(handle: zio.Handle) @This() {
        return @This() { .inner = zio.backend.Poller.fromHandle(handle) };
    }

    pub const RegisterError = error {
        // TODO
    };

    pub const OneShot = 1 << 0;
    pub const Readable = 1 << 1;
    pub const Writeable = 1 << 2;
    
    pub inline fn register(self: *@This(), handle: zio.Handle, flags: u8, data: usize) RegisterError!void {
        return self.inner.register(handle, flags, data);
    }

    pub inline fn reregister(self: *@This(), handle: zio.Handle, flags: u8, data: usize) RegisterError!void {
        return self.inner.reregister(handle, flags, data);
    }

    pub const SendError = error {
        // TODO
    };

    pub inline fn send(self: *@This(), data: usize) SendError!void {
        return self.inner.send(data);
    }

    pub const PollError = error {
        // TODO
    };

    pub inline fn poll(self: *@This(), events: []Event, timeout: ?u32) PollError![]Event {
        const events = try self.inner.poll(@ptrCast([*]zio.backend.Event, events.ptr)[0..events.len], timeout);
        return @ptrCast([*]Event, events.ptr)[0..events.len];
    }
};