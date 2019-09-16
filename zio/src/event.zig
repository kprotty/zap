const std = @import("std");
const zio = @import("../zio.zig");

pub const Event = struct {
    inner: zio.backend.Event,

    pub const Flags = u8;
    pub const OneShot: Flags = 1 << 0;
    pub const Readable: Flags = 1 << 1;
    pub const Writeable: Flags = 1 << 2;
    pub const EdgeTrigger: Flags = 1 << 3;

    pub fn readData(self: *@This(), poller: *Poller) usize {
        return self.inner.readData(&poller.inner);
    }

    pub fn readFlags(self: *@This(), duplex_type: zio.DuplexType) Flags {
        return self.inner.readFlags(duplex_type);
    }

    pub const Poller = struct {
        inner: zio.backend.Event.Poller,

        pub const Error = error {
            // TODO
        };

        pub fn new() Error!@This() {
            const poller = try zio.backend.Event.Poller.new();
            return @This() { .inner = poller };
        }

        pub const RegisterError = error {
            // TODO
        };

        pub fn register(self: *@This(), handle: zio.Handle, flags: Event.Flags, user_data: usize) RegisterError!void {
            return self.inner.register(handle, flags, user_data);
        }

        pub fn reregister(self: *@This(), handle: zio.Handle, flags: Event.Flags, user_data: usize) RegisterError!void {
            return self.inner.reregister(handle, flags, user_data);
        }

        pub const NotifyError = error {
            // TODO
        };

        pub fn notify(self: *@This(), user_data: usize) NotifyError!void {
            return self.inner.notify(user_data);
        }

        pub const PollError = error {
            // TODO
        };

        pub fn poll(self: *@This(), events: []Event, timeout_ms: ?usize) PollError![]Event {
            const events_found = try self.inner.poll(@ptrCast([*]zio.backend.Event, events.ptr)[0..events.len], timeout_ms);
            return @ptrCast([*]Event, events_found.ptr)[0..events_found.len];
        }
    }
};
