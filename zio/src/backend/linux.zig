const std = @import("std");
const posix = @import("posix.zig");
const zio = @import("../../../zap.zig").zio;

const os = std.os;
const linux = os.linux;

pub const Handle = posix.Handle;
pub const Socket = posix.Socket;
pub const Buffer = posix.Buffer;

pub const IncomingPadding = posix.IncomingPadding;
pub const SockAddr = posix.SockAddr;
pub const Ipv4 = posix.Ipv4;
pub const Ipv6 = posix.Ipv6;

pub const Event = struct {
    inner: linux.epoll_event,

    pub fn readData(self: @This(), poller: *Poller) usize {
        if (self.inner.data.ptr != ~usize(0))
            return self.inner.data.ptr;
        var value: u64 = undefined;
        const bytes = linux.read(poller.event_fd, @ptrCast([*]u8, &value), @sizeOf(@typeOf(value)));
        return if (bytes == @sizeOf(@typeOf(value))) @truncate(usize, value) else 0;
    }

    pub fn getToken(self: @This()) usize {
        var token: usize = 0;
        if ((self.inner.events & linux.EPOLLIN) != 0)
            token |= zio.Event.Readable;
        if ((self.inner.events & linux.EPOLLOUT) != 0)
            token |= zio.Event.Writeable;
        if ((self.inner.events & (linux.EPOLLERR | linux.EPOLLHUP)) != 0)
            token |= zio.Event.Disposable;
        return token;
    }

    pub const Poller = struct {
        epoll_fd: Handle,
        event_fd: Handle,

        pub fn new() zio.Event.Poller.Error!@This() {
            const epoll_fd = linux.epoll_create1(linux.EPOLL_CLOEXEC);
            return switch (linux.getErrno(epoll_fd)) {
                0 => @This(){
                    .event_fd = 0,
                    .epoll_fd = @intCast(Handle, epoll_fd),
                },
                linux.EMFILE, linux.ENOMEM => zio.Event.Poller.Error.OutOfResources,
                linux.EINVAL => unreachable,
                else => unreachable,
            };
        }

        pub fn close(self: *@This()) void {
            _ = linux.close(self.epoll_fd);
            if (self.event_fd != 0)
                _ = linux.close(self.event_fd);
        }

        pub fn getHandle(self: @This()) zio.Handle {
            return self.epoll_fd;
        }

        pub fn fromHandle(handle: zio.Handle) @This() {
            return @This(){
                .epoll_fd = handle,
                .event_fd = 0,
            };
        }

        pub fn register(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            if (data == ~usize(0))
                return zio.Event.Poller.RegisterError.InvalidValue;
            return self.epoll_ctl(handle, linux.EPOLL_CTL_ADD, flags, data);
        }

        pub fn reregister(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            if (data == ~usize(0))
                return zio.Event.Poller.RegisterError.InvalidValue;
            return self.epoll_ctl(handle, linux.EPOLL_CTL_MOD, flags, data);
        }

        pub fn notify(self: *@This(), data: usize) zio.Event.Poller.NotifyError!void {
            if (self.event_fd == 0) {
                const event_fd = linux.eventfd(0, linux.EFD_NONBLOCK | linux.EFD_CLOEXEC);
                switch (linux.getErrno(event_fd)) {
                    0 => self.event_fd = @intCast(Handle, event_fd),
                    linux.EMFILE, linux.ENFILE, linux.ENODEV, linux.ENOMEM => return zio.Event.Poller.NotifyError.OutOfResources,
                    linux.EINVAL => unreachable,
                    else => unreachable,
                }
                try self.epoll_ctl(self.event_fd, linux.EPOLL_CTL_ADD, zio.Event.Readable | zio.Event.EdgeTrigger, ~usize(0));
            }

            var value = @intCast(u64, data);
            const errno = linux.getErrno(linux.write(self.event_fd, @ptrCast([*]u8, &value), @sizeOf(@typeOf(value))));
            if (errno != 0)
                return std.os.unexpectedErrno(errno);
        }

        pub fn poll(self: *@This(), events: []Event, timeout: ?u32) zio.Event.Poller.PollError![]Event {
            const timeout_ms = if (timeout) |t| @intCast(i32, t) else -1;
            const events_ptr = @ptrCast([*]linux.epoll_event, events.ptr);
            while (true) {
                const events_found = linux.epoll_wait(self.epoll_fd, events_ptr, @intCast(u32, events.len), timeout_ms);
                switch (linux.getErrno(events_found)) {
                    0 => return events[0..events_found],
                    linux.EBADF, linux.EINVAL => return zio.Event.Poller.PollError.InvalidHandle,
                    linux.EFAULT => return zio.Event.Poller.PollError.InvalidEvents,
                    linux.EINTR => continue,
                    else => unreachable,
                }
            }
        }

        fn epoll_ctl(self: @This(), handle: Handle, op: u32, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            var event = linux.epoll_event{
                .data = linux.epoll_data{ .ptr = data },
                .events = 0,
            };

            if ((flags & zio.Event.Readable) != 0)
                event.events |= linux.EPOLLIN;
            if ((flags & zio.Event.Writeable) != 0)
                event.events |= linux.EPOLLOUT;
            if ((flags & zio.Event.EdgeTrigger) != 0) {
                event.events |= linux.EPOLLET;
            } else {
                event.events |= linux.EPOLLONESHOT;
            }

            return switch (linux.getErrno(linux.epoll_ctl(self.epoll_fd, op, handle, &event))) {
                0 => {},
                linux.EBADF, linux.EINVAL, linux.ELOOP, linux.ENOENT, linux.EPERM => zio.Event.Poller.RegisterError.InvalidValue,
                linux.ENOMEM, linux.ENOSPC => zio.Event.Poller.RegisterError.OutOfResources,
                else => unreachable,
            };
        }
    };
};
