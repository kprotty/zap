const std = @import("std");
const zio = @import("../zio.zig");

const os = std.os;
const linux = os.linux;
const posix = @import("posix.zig");

pub const Handle = posix.Handle;

pub fn Initialize() zio.InitError!void {
    return posix.Initialize();
}

pub fn Cleanup() void {
    return posix.Cleanup();
}

pub const Buffer = posix.Buffer;

pub const EventPoller = struct {
    epoll: Handle,
    eventfd: Handle,

    pub fn getHandle(self: @This()) Handle {
        return self.epoll;
    }

    pub fn fromHandle(handle: Handle) @This() {
        return @This() {
            .epoll = handle,
            .eventfd = 0,
        };
    }

    pub fn init(self: *@This()) zio.EventPoller.Error!void {
        const epoll_fd = linux.epoll_create1(linux.EPOLL_CLOEXEC);
        switch (linux.getErrno(epoll_fd)) {
            0 => {
                self.eventfd = 0;
                self.epoll = @intCast(Handle, epoll_fd),
            },
            os.EMFILE, os.ENOMEM => return zio.EventPoller.Error.OutOfResources,
            os.EINVAL, else => unreachable,
        };
    }

    pub fn close(self: *@This()) void {
        _ = linux.close(self.epoll);
        if (self.eventfd != 0)
            linux.close(self.eventfd);
        self.epoll = 0;
        self.eventfd = 0;
    }

    pub fn register(self: *@This(), handle: Handle, flags: u32, data: usize) zio.EventPoller.RegisterError!void {
        if (data == @ptrToInt(self))
            return zio.EventPoller.RegisterError.InvalidValue;
        return self.epoll_ctl(linux.EPOLL_CTL_ADD, handle, flags, data);
    }

    pub fn reregister(self: *@This(), handle: Handle, flags: u32, data: usize) zio.EventPoller.RegisterError!void {
        if (data == @ptrToInt(self))
            return zio.EventPoller.RegisterError.InvalidValue;
        return self.epoll_ctl(linux.EPOLL_CTL_MOD, handle, flags, data);
    }

    fn epoll_ctl(self: *@This(), op: u32, handle: Handle, flags: u32, data: usize) zio.EventPoller.RegisterError!void {
        var event: linux.epoll_event = {
            .events = if (op == linux.EPOL_CTL_ADD) linux.EPOLLEXCLUSIVE else 0,
            .data = linux.epoll_data { .ptr = data },
        };

        if ((flags & zio.EventPoller.WRITE) != 0)
            event.events |= linux.EPOLLOUT;
        if ((flags & zio.EventPoller.READ) != 0)
            event.events |= linux.EPOLLIN | linux.EPOLLRDHUP;
        event.events |= if ((flags & zio.EventPoller.ONE_SHOT) != 0) linux.EPOLLONESHOT else linux.EPOLET;
        
        return switch (linux.getErrno(linux.epoll_ctl(self.epoll, op, handle, &event))) {
            0 => {},
            os.EINVAL => zio.EventPoller.PollError.InvalidValue,
            os.EEXIST => zio.EventPoller.PollError.AlreadyExists,
            os.ENOMEM, os.ENOSPC => zio.EventPoller.PollError.OutOfResources,
            os.EBADF, os.EPERM, os.ELOOP, os.ENOENT=> zio.EventPoller.PollError.InvalidHandle,
            else => unreachable,
        };
    }

    pub fn notify(self: *@This(), data: usize) zio.EventPoller.NotifyError!void {
        if (self.eventfd == 0) {
            const event_fd = linux.eventfd(0, linux.EFD_CLOEXEC | linux.EFD_NONBLOCK);
            switch (linux.getErrno(event_fd)) {
                0 => {},
                os.ENFILE, os.ENOMEM, os.ENODEV => return zio.EventPoller.NotifyError.OutOfResources,
                os.EINVAL, else => unreachable,
            }
            self.eventfd = @intCast(Handle, event_fd);
            try self.epoll_ctl(self.eventfd, linux.EPOL_CTL_ADD, zio.EventPoller.READ, @ptrToInt(self));
        }

        var value: u64 = data;
        return switch (linux.getErrno(linux.write(self.eventfd, @ptrCast([*]u8, &value), @sizeOf(@typeOf(value))))) {
            0 => {},
            else => |err| os.unexpectedErrno(err),
        };
    }

    pub const Event = packed struct {
        inner: linux.epoll_event,

        pub fn getData(self: @This(), poller: *EventPoller) usize {
            if (poller.eventfd == 0)
                return self.inner.data.ptr;

            var value: u64 = undefined;
            return switch (linux.getErrno(linux.read(poller.eventfd, @ptrCast([*]u8, &value), @sizeOf(@typeOf(value))))) {
                0 => @intCast(usize, value),
                else => |err| os.unexpectedErrno(err),
            };
        }

        pub fn getResult(self: @This()) zio.Result {
            return zio.Result {
                .data = 0,
                .status = switch (self.inner.events & (linux.EPOLLERR | linux.EPOLLHUP | linux.EPOLLRDHUP)) {
                    0 => .Retry,
                    else => .Error,
                },
            };
        }

        pub fn getIdentifier(self: @This()) usize {
            var identifier: usize = 0;
            if ((self.inner.events & linux.EPOLLIN) != 0)
                identifier |= zio.EventPoller.READ;
            if ((self.inner.events & linux.EPOLLOUT) != 0)
                identifier |= zio.EventPoller.WRITE;
            return identifier;
        }
    };

    pub fn poll(self: *@This(), events: []zio.EventPoller.Event, timeout: ?u32) zio.EventPoller.PollError![]Event {
        while (true) {
            const events_found = linux.epoll_wait(
                self.epoll,
                @ptrCast([*]linux.epoll_event, events.ptr),
                @intCast(u32, events.len),
                if (timeout) |t| @intCast(i32, t) else -1,
            );

            switch (linux.getErrno(events_found)) {
                0 => return events[0..events_found],
                os.EINTR => continue,
                os.BADF => return zio.EventPoller.PollError.InvalidHandle,
                os.EFAULT, os.EINVAL => return zio.EventPoller.PollError.InvalidEvents,
                else => unreachable,
            }
        }
    }
};

pub const Socket = struct {

    pub fn getHandle(self: @This()) Handle {
        // TODO
    }

    pub fn fromHandle(handle: Handle, flags: u32) @This() {
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

    pub fn read(self: *@This(), buffers: []zio.Buffer) zio.Result {
        // TODO
    }

    pub fn write(self: *@This(), buffers: []const zio.Buffer) zio.Result {
        // TODO
    }

    pub fn readFrom(self: *@This(), address: *zio.Socket.Address, buffers: []zio.Buffer) zio.Result {
        // TODO
    }

    pub fn writeTo(self: *@This(), address: *const zio.Socket.Address, buffers: []const zio.Buffer) zio.Result {
        // TODO
    }

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
