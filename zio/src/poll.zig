const std = @import("std");
const zio = @import("../zio.zig");

/// An EventPoller is used to listen to & generate IO events for non-blocking resource objects.
pub const EventPoller = struct {
    inner: zio.backend.EventPoller,

    /// Get the underlying Handle for this resource object
    pub inline fn getHandle(self: @This()) zio.Handle {
        return self.inner.getHandle();
    }

    /// Create an `EventPoller` from a Handle.
    // There should not exist more than one EventPoller active at a given point.
    /// It is also undefined behavior to call this method after previously calling `notify()`
    pub inline fn fromHandle(handle: zio.Handle) @This() {
        return @This() { .inner = zio.backend.EventPoller.fromHandle(handle) };
    }

    pub const Error = std.os.UnexpectedError || error {
        InvalidHandle,
        OutOfResources,
    };

    /// Initialize the EventPoller
    pub inline fn init(self: *@This()) Error!void {
        return self.inner.init();
    }

    /// Close this resource object
    pub inline fn close(self: *@This()) void {
        return self.inner.close();
    }

    pub const NotifyError = RegisterError;

    /// Generate a user-based event with the `data` being arbitrary user data.
    /// Most noteably used for communicating with an `EventPoller` which is blocked polling.
    /// `Event`s originating from a `notify()` call are always Readable and never Writeable.
    pub inline fn notify(self: *@This(), data: usize) NotifyError!void {
        return self.inner.notify(data);
    }

    pub const READ:         u32 = 1 << 0;
    pub const WRITE:        u32 = 1 << 1;
    pub const ONE_SHOT:     u32 = 1 << 2;
    pub const EDGE_TRIGGER: u32 = 1 << 3;

    pub const RegisterError = Error || error {
        InvalidValue,
        AlreadyExists,
    };

    /// In order for the `EventPoller` to receive IO events,
    /// one should register the IO resource object under the event poller.
    /// `data`: arbitrary user data which can be retrieved when polling for events.
    ///     `data` of `@ptrToInt(self)` may return `RegisterError.InvalidValue`
    /// `flags`: it a bitmask of IO events to listen for and how:
    ///     - READ: an event will be generated once the resource object is readable.
    ///     - WRITE: an event will be generated onec the resource object is writeable.
    ///     - ONE_SHOT: once an event is consumed, it will no longer be generated and can be re-registered.
    ///     - EDGE_TRIGGER(defualt): once an event is consumed, it can be regenerated after the corresponding operation completes
    pub inline fn register(self: *@This(), handle: zio.Handle, flags: u32, data: usize) RegisterError!void {
        return self.inner.register(handle, flags, data);
    }

    /// Similar to `register()` but should be called to re-register an event 
    /// if the handle was previously registerd with `ONE_SHOT`.
    /// This is most noteably called after a `Result.Status.Partial` operation registered with `ONE_SHOT`.
    pub inline fn reregister(self: *@This(), handle: zio.Handle, flags: u32, data: usize) RegisterError!void {
        return self.inner.reregister(handle, flags, data);
    }

    /// A notification of an IO operation status - a.k.a. an IO event.
    pub const Event = struct {
        inner: zio.backend.EventPoller.Event,

        /// Get the arbitrary user data tagged to the event when registering under the `poller`.
        /// Should be called only once as it consumes the event data and is UB if called again.
        pub inline fn getData(self: @This(), poller: *EventPoller) usize {
            return self.inner.getData(&poller.inner);
        }

        /// Get the result of the corresponding IO operation to continue processing
        pub inline fn getResult(self: @This()) Result {
            return self.inner.getResult();
        }

        /// Get an identifier which can be used with `.isReadable()` or `.isWriteable()`
        /// in order to help identify which pipe this event originated from.
        pub inline fn getIdentifier(self: @This()) usize {
            return self.inner.getIdentifier();
        }
    };

    pub const PollError = Error || error {
        InvalidEvents,
    };

    /// Poll for `Event` objects that have been ready'd by the kernel.
    /// `timeout`: amount of milliseconds to block until one or more events are ready'd.
    ///     - if `timeout` is null, then poll() will block indefinitely until an event is ready'd
    ///     - if `timeout` is 0, then poll() will return with any events that were immediately ready'd (can be empty)
    pub inline fn poll(self: *@This(), events: []Event, timeout: ?u32) PollError![]Event {
        return self.inner.poll(events, timeout);
    }
};

const expect = std.testing.expect;
// TODO: Implement pipes in order to test out register/reregister
// TODO: Implement zuma.now() in order to test poll() blocking timing.

test "EventPoller - poll - nonblock" {
    var poller: EventPoller = undefined;
    try poller.init();
    defer poller.close();

    var events: [1]EventPoller.Event = undefined;
    const events_found = try poller.poll(events[0..], 0);
    expect(events_found.len == 0);
}

test "EventPoller - notify" {
    var poller: EventPoller = undefined;
    try poller.init();
    defer poller.close();

    const value = usize(1234);
    try poller.notify(value);

    var events: [1]EventPoller.Event = undefined;
    const events_found = try poller.poll(events[0..], 0);
    expect(events_found.len == 1);

    const data = events_found[0].getData(&poller);
    expect(data == value);
    const identifier = events_found[0].getIdentifier();
    expect(identifier == EventPoller.READ or identifier == 0);
}

