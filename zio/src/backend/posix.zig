const std = @import("std");
const builtin = @import("builtin");
const zio = @import("../../zio.zig");

const os = std.os;
const system = os.system;

/// Needs to possibly return an error for the return type :/
var dummy_var: u8 = 0;
pub fn initialize() zio.InitError!void {
    if (@ptrCast(*volatile u8, &dummy_var).* != 0)
        return zio.InitError.InvalidState;
}

pub fn cleanup() void {
    // nothing to clean up
}

pub const Handle = i32;

pub const Buffer = struct {
    inner: os.iovec_const,

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This() {
            .inner = os.iovec_const {
                .iov_base = bytes.ptr,
                .iov_len = bytes.len,
            }
        };
    }

    pub fn getBytes(self: @This()) []u8 {
        return self.inner.iov_base[0..self.inner.iov_len];
    }
};

/// Linux doesnt need any dumb padding or Incoming buffer at all
pub const IncomingPadding = 0;

pub const Ipv4 = packed struct {
    inner: os.sockaddr_in,

    pub fn from(address: u32, port: u16) @This() {
        return @This() {
            .inner = os.sockaddr_in {
                .sin_family = os.AF_INET,
                .sin_port = std.mem.nativeToBig(@typeOf(port), port),
                .sin_zero = [_]u8{0} * @sizeOf(@typeOf(os.sockaddr_in(undefined).sin_zero)),
                .sin_addr = os.in_addr { .s_addr = std.mem.nativeToBig(@typeOf(address), address) },
            }
        };
    }
};

pub const Ipv6 = packed struct {
    inner: os.sockaddr_in6,

    pub fn from(address: u128, port: u16, flow: u32, scope: u32) @This() {
        return @This() {
            .inner = os.sockaddr_in6 {
                .sin6_family = os.AF_INET6,
                .sin6_port = std.mem.nativeToBig(@typeOf(port), port),
                .sin6_flowinfo = std.mem.nativeToBig(@typeOf(flow), flow),
                .sin6_scope_id = std.mem.nativeToBig(@typeOf(scope), scope),
                .sin6_addr = os.in_addr6 { .Qword = std.mem.nativeToBig(@typeOf(address), address) },
            }
        };
    }
};

pub const Event = struct {
    inner: os.Kevent,

    pub fn getData(self: *@This(), poller: *Poller) usize {
        return self.inner.udata;
    }

    pub fn getResult(self: *@This()) zio.Result {
        return zio.Result {
            .data = self.inner.data,
            .status = switch (self.inner.flags & (os.EV_EOF | os.EV_ERROR)) {
                0 => .Retry,
                else => .Error,
            }
        };
    }

    pub const Poller = struct {
        kqueue: Handle,

        pub fn init(self: *@This()) zio.Event.Poller.InitError!void {
            const kqueue = os.kqueue();
            return switch (os.errno(kqueue)) {
                0 => self.kqueue = @intCast(Handle, kqueue),
                os.ENOMEM => zio.Event.Poller.InitError.OutOfResources,
                else => unreachable,
            };
        }

        pub fn close(self: *@This()) void {
            _ = os.close(self.kqueue);
        }

        pub fn getHandle(self: @This()) zio.Handle {
            return self.kqueue;
        }

        pub fn fromHandle(handle: zio.Handle) @This() {
            return @This() { .kqueue = handle };
        }

        pub fn register(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            var num_events: usize = 0;
            var events: [2]os.Kevent = undefined;

            events[0].flags = os.EV_ADD | if ((flags & zio.Event.OneShot) != 0) os.EV_ONESHOT else os.EV_CLEAR;
            events[0].ident = @intCast(usize, handle);
            events[0].udata = data;
            events[0].fflags = 0;
            events[1] = events[0];
            
            if ((flags & zio.Event.Readable) != 0) {
                events[num_events].filter = os.EVFILT_READ;
                num_events += 1;
            }
            if ((flags & zio.Event.Writeable) != 0) {
                events[num_events].filter = os.EVFILT_WRITE;
                num_events += 1;
            }
            if (num_events == 0)
                return zio.Event.Poller.RegisterError.InvalidValue;
            return self.kevent(events[0..num_events], ([*]os.Kevent)(undefined)[0..0], null);
        }

        pub fn reregister(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            return self.register(handle, flags, data);
        }

        pub fn send(self: *@This(), data: usize) zio.Event.Poller.SendError!void {
            var events: [1]os.Kevent = undefined;
            events[0] = os.Kevent {
                .data = 0,
                .flags = 0,
                .udata = data,
                .filter = os.EVFILT_USER,
                .fflags = os.NOTE_TRIGGER,
                .ident = @intCast(usize, self.kqueue),
            };

            return self.kevent(events[0..], ([*]os.Kevent)(undefined)[0..0], null) catch |err| switch (err) {
                .InvalidEvents => unreachable,
                else => |err| err,
            };
        }

        pub fn poll(self: *@This(), events: []Event, timeout: ?u32) zio.Event.Poller.PollError![]Event {
            const empty_set = ([*]os.Kevent)(undefined)[0..0];
            const event_set = @ptrCast([*]os.Kevent, events.ptr)[0..events.len];
            return self.kevent(empty_set, event_set, timeout);
        }

        fn kevent(self: *@This(), change_set: []os.Kevent, event_set: []os.Kevent, timeout: ?u32) zio.Event.Poller.PollError!usize {
            var ts: os.timespec = undefined;
            var ts_ptr: ?*os.timespec = null;
            if (timeout) |timeout_ms| {
                ts.tv_nsec = (timeout_ms % 1000) * 1000000;
                ts.tv_sec = timeout_ms / 1000;
                ts_ptr = &ts;
            }

            while (true) {
                const events_found = os.kevent(self.kqueue, change_set.ptr, change_set.len, event_set.ptr, event_set.len, ts_ptr);
                switch (os.errno(events_found)) {
                    0 => return event_set[0..events_found],
                    os.EACCES, os.EFAULT, os.ENOENT, os.ENOMEM => return zio.Event.Poller.PollError.InvalidEvents,
                    os.ESRCH, os.EBADF => return zio.Event.Poller.PollError.InvalidHandle,
                    os.EINVAL => unreachable,
                    os.EINTR => continue,
                    else => unreachable,
                }
            }
        }
    };
};

pub const Socket = struct {

    pub fn init(self: *@This(), flags: u8) zio.Socket.InitError!void {
        
    }

    pub fn close(self: *@This()) void {
        
    }

    pub fn getHandle(self: @This()) zio.Handle {
        
    }

    pub fn fromHandle(handle: zio.Handle) @This() {
        
    }

    pub fn isReadable(self: *const @This(), event: Event) bool {
        
    }

    pub fn isWriteable(self: *const @This(), event: Event) bool {
        
    }

    pub fn setOption(option: Option) zio.Socket.OptionError!void {
       
    }

    pub fn getOption(option: *Option) zio.Socket.OptionError!void {
        
    }

    pub fn bind(self: *@This(), address: *const zio.Address) zio.Socket.BindError!void {
        
    }

    pub fn listen(self: *@This(), backlog: u16) zio.Socket.ListenError!void {
        
    }

    pub fn connect(self: *@This(), address: *const zio.Address) zio.Result {
        
    }

    pub fn accept(self: *@This(), incoming: *zio.Address.Incoming) zio.Result {
        
    }

    pub fn recv(self: *@This(), address: ?*zio.Address, buffers: []zio.Buffer) zio.Result {
        
    }

    pub fn send(self: *@This(), address: ?*const zio.Address, buffers: []const zio.Buffer) zio.Result {
        
    }
};