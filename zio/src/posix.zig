const std = @import("std");
const zio = @import("../zio.zig");

const os = std.os;
const system = os.system;

pub const Handle = i32;

// needs to throw some type of error for the compiler to not complain :/
var dummy_var: usize = 0;
pub fn Initialize() zio.InitError!void {
    if (@ptrCast(*volatile usize, &dummy_var).* != 0)
        return zio.InitError.InvalidSystemState;
}

pub fn Cleanup() void {
    // nothing to do here, keep scrolling
}

pub const Buffer = packed struct {
    inner: system.iovec_const,

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This() {
            .inner = system.iovec {
                .iov_len = bytes.len,
                .iov_base = bytes.ptr,
            }
        };
    }

    pub fn getBytes(self: @This()) []u8 {
        // rust would be screaming right now ;-)
        @intToPtr([*]u8, @ptrToInt(self.inner.iov_base))[0..self.inner.iov_len];
    }
};

pub const EventPoller = struct {
    kqueue: Handle,

    pub fn getHandle(self: @This()) Handle {
        return self.kqueue;
    }

    pub fn fromHandle(handle: Handle) @This() {
        return @This() { .kqueue = handle };
    }

    pub fn init(self: *@This()) zio.EventPoller.Error!void {
        const kqueue = system.kqueue();
        switch (system.getErrno(kqueue)) {
            0 => self.kqueue = @intCast(Handle, kqueue),
            os.ENOMEM => return zio.EventPoller.Error.OutOfResources,
            else => |err| return os.unexpectedErrno(err),
        }
    }

    pub fn close(self: *@This()) void {
        _ = system.close(self.kqueue);
    }

    pub fn register(self: *@This(), handle: Handle, flags: u32, data: usize) zio.EventPoller.RegisterError!void {
        var num_events: usize = 0;
        var events: [2]system.Kevent = undefined;

        events[0].flags = system.EV_ADD | if ((flags & zio.EventPoller.ONE_SHOT) != 0) system.EV_ONESHOT else system.EV_CLEAR;
        events[0].ident = @intCast(usize, handle);
        events[0].udata = data;
        events[0].fflags = 0;
        events[1] = events[0];
        
        if ((flags & zio.EventPoller.READ) != 0) {
            events[num_events].filter = system.EVFILT_READ;
            num_events += 1;
        }
        if ((flags & zio.EventPoller.WRITE) != 0) {
            events[num_events].filter = system.EVFILT_WRITE;
            num_events += 1;
        }
        if (num_events == 0)
            return zio.EventPoller.RegisterError.InvalidValue;
        return self.kevent(events[0..num_events], ([*]system.Kevent)(undefined)[0..0], null);
    }

    pub fn reregister(self: *@This(), handle: Handle, flags: u32, data: usize) zio.EventPoller.RegisterError!void {
        return self.register(handle, flags, data);
    }

    pub fn notify(self: *@This(), data: usize) zio.EventPoller.NotifyError!void {
        var events: [1]system.Kevent = undefined;
        events[0] = system.Kevent {
            .data = 0,
            .flags = 0,
            .udata = data,
            .filter = system.EVFILT_USER,
            .fflags = system.NOTE_TRIGGER,
            .ident = @intCast(usize, self.kqueue),
        };

        return self.kevent(events[0..], ([*]system.Kevent)(undefined)[0..0], null) catch |err| switch (err) {
            .InvalidEvents => unreachable,
            else => |err| err,
        };
    }

    pub const Event = packed struct {
        inner: system.Kevent,

        pub fn getData(self: @This(), poller: *EventPoller) usize {
            return self.inner.udata;
        }

        pub fn getResult(self: @This()) zio.Result {
            return zio.Result {
                .transferred = @intCast(usize, self.inner.data),
                .status = switch (self.inner.flags & (system.EV_EOF | system.EV_ERROR)) {
                    0 => .Retry,
                    else => .Error,
                },
            };
        }

        pub fn getIdentifier(self: @This()) usize {
            return switch (self.inner.filter) {
                system.EVFILT_USER, system.EVFILT_READ => zio.EventPoller.READ,
                system.EVFILT_WRITE => zio.EventPoller.WRITE,
                else => 0,
            };
        }
    };

    pub fn poll(self: *@This(), events: []zio.EventPoller.Event, timeout: ?u32) zio.EventPoller.PollError![]Event {
        return self.kevent(([*]system.Kevent)(undefined)[0..0], @bytesToSlice(system.Kevent, @sliceToBytes(events)), timeout);  
    }

    fn kevent(self: *@This(), change_set: []system.Kevent, event_set: []system.Kevent, timeout: ?u32) zio.EventPoller.PollError!usize {
        var ts: system.timespec = undefined;
        const ts_ptr = value: if (timeout) |timeout_ms| {
            ts.tv_nsec = (timeout_ms % 1000) * 1000000;
            ts.tv_sec = timeout_ms / 1000;
            break :value &ts;
        } else {
            break :value null;
        };
        
        while (true) {
            const events_found = system.kevent(self.kqueue, change_set.ptr, change_set.len, event_set.ptr, event_set.len, ts_ptr);
            switch (system.getErrno(events_found)) {
                0 => return event_set[0..events_found],
                os.EINTR => continue,
                os.EINVAL => unreachable,
                os.ESRCH, os.EBADF => return zio.EventPoller.PollError.InvalidHandle,
                os.EACCES, os.EFAULT, os.ENOENT, os.ENOMEM => return zio.EventPoller.PollError.InvalidEvents,
                else => |err| return os.unexpectedErrno(err),
            }
        }
    }
};

pub const Socket = struct {

    pub fn getHandle(self: @This()) Handle {
        // TODO
    }

    pub fn fromHandle(handle: Handle) @This() {
        // TODO
    }

    pub fn init(self: *@This(), flags: u32) zio.Socket.Error!void {
        // TODO
    }
    
    pub fn close(self: *@This()) void {
        // TODO
    }

    pub fn isReadable(self: *@This(), identifier: usize) bool {
        // TODO
    }

    pub fn isWriteable(self: *@This(), identifier: usize) bool {
        // TODO
    }

    pub fn setOption(option: Option) zio.Socket.OptionError!void {
        // TODO
    }

    pub fn getOption(option: *Option) zio.Socket.OptionError!void {
        // TODO
    }

    pub fn read(self: *@This(), buffers: []zio.Buffer) zio.Result {
        // TODO
    }

    pub fn write(self: *@This(), buffers: []const zio.Buffer) zio.Result {
        // TODO
    }

    pub const Ipv4 = packed struct {

        pub fn from(address: u32, port: u16) @This() {
            // TODO
        }
    };

    pub const Ipv6 = packed struct {

        pub fn from(address: u128, port: u16) @This() {
            // TODO
        }
    };

    pub fn bind(self: *@This(), address: *zio.Socket.Address) zio.Socket.BindError!void {
        // TODO
    }

   
    pub fn listen(self: *@This(), backlog: u16) zio.Socket.ListenError!void {
        // TODO
    }

    pub fn accept(self: *@This(), address: *zio.Socket.Address) zio.Result {
        // TODO
    }

    pub fn connect(self: *@This(), address: *zio.Socket.Address) zio.Result {
        // TODO
    }
};
