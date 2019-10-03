const std = @import("std");
const zio = @import("zap").zio;
const expect = std.testing.expect;

pub const Event = struct {
    inner: zio.backend.Event,

    pub const Flags = u8;
    pub const OneShot: Flags = 1 << 0;
    pub const Readable: Flags = 1 << 1;
    pub const Writeable: Flags = 1 << 2;
    pub const Disposable: Flags = 1 << 3;
    pub const EdgeTrigger: Flags = 1 << 4;

    pub fn getToken(self: @This()) usize {
        return self.inner.getToken();
    }

    pub fn readData(self: @This(), poller: *Poller) usize {
        return self.inner.readData(&poller.inner);
    }

    pub const Poller = struct {
        inner: zio.backend.Event.Poller,

        pub const Error = std.os.UnexpectedError || error {
            OutOfResources,
        };

        pub fn new() Error!@This() {
            const poller = try zio.backend.Event.Poller.new();
            return @This() { .inner = poller };
        }

        pub fn close(self: *@This()) void {
            self.inner.close();
        }

        pub fn fromHandle(handle: zio.Handle) @This() {
            return @This() { .inner = zio.Event.Poller.fromHandle(handle) };
        }

        pub fn getHandle(self: @This()) zio.Handle {
            return self.inner.getHandle();
        }

        pub const RegisterError = std.os.UnexpectedError || error {
            InvalidValue,
            OutOfResources,
        };

        pub fn register(self: *@This(), handle: zio.Handle, flags: Event.Flags, user_data: usize) RegisterError!void {
            return self.inner.register(handle, flags, user_data);
        }

        pub fn reregister(self: *@This(), handle: zio.Handle, flags: Event.Flags, user_data: usize) RegisterError!void {
            return self.inner.reregister(handle, flags, user_data);
        }

        pub const NotifyError = std.os.UnexpectedError || error {
            InvalidValue,
            InvalidHandle,
            OutOfResources,
        };

        pub fn notify(self: *@This(), user_data: usize) NotifyError!void {
            return self.inner.notify(user_data);
        }

        pub const PollError = std.os.UnexpectedError || error {
            InvalidHandle,
            InvalidEvents,
        };

        pub fn poll(self: *@This(), events: []Event, timeout_ms: ?u32) PollError![]Event {
            const events_found = try self.inner.poll(@ptrCast([*]zio.backend.Event, events.ptr)[0..events.len], timeout_ms);
            return @ptrCast([*]Event, events_found.ptr)[0..events_found.len];
        }
    };
};

test "Event.Poller - poll - nonblock" {
    var poller = try Event.Poller.new();
    defer poller.close();

    var events: [1]Event = undefined;
    const events_found = try poller.poll(events[0..], 0);
    expect(events_found.len == 0);
}

test "Event.Poller - notify" {
    var poller = try Event.Poller.new();
    defer poller.close();

    const value = usize(1234);
    try poller.notify(value);

    var events: [1]Event = undefined;
    const events_found = try poller.poll(events[0..], 0);
    expect(events_found.len == 1);
    expect(events_found[0].readData(&poller) == value);
}
