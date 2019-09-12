const std = @import("std");
const posix = @import("posix.zig");
const zio = @import("../../zio.zig");

const os = std.os;
const linux = os.linux;

pub const initialize = posix.initialize;
pub const cleanup = posix.cleanup;

pub const Handle = posix.Handle;
pub const Buffer = posix.Buffer;

pub const Ipv4 = posix.Ipv4;
pub const Ipv6 = posix.Ipv6;

pub const Event = struct {
    inner: linux.epoll_event,

    pub fn getData(self: *@This(), poller: *Poller) usize {
        if (self.inner.data.ptr != ~usize(0))
            return self.inner.data.ptr;
        var value: u64 = undefined;
        const bytes = linux.read(poller.event_fd, @ptrCast([*]u8, &value), @sizeOf(@typeOf(value)));
        return if (bytes == @sizeOf(@typeOf(value))) @truncate(usize, value) else 0;
    }

    pub fn getResult(self: *@This()) zio.Result {
        return zio.Result {
            .data = 0,
            .status = switch (self.inner.events & (linux.EPOLLERR | linux.EPOLLHUP | linux.EPOLLRDHUP)) {
                0 => .Retry,
                else => .Error,
            },
        };
    }

    pub const Poller = struct {
        epoll_fd: Handle,
        event_fd: Handle,

        pub fn init(self: *@This()) zio.Event.Poller.InitError!void {
            self.event_fd = 0;
            const epoll_fd = linux.epoll_create1(linux.EPOLL_CLOEXEC);
            return switch (linux.getErrno(epoll_fd)) {
                0 => self.epoll_fd = @intCast(Handle, epoll_fd),
                os.EMFILE, os.ENOMEM => zio.Event.Poller.InitError.OutOfResources,
                os.EINVAL => unreachable,
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
            return @This() {
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

        pub fn send(self: *@This(), data: usize) zio.Event.Poller.SendError!void {
            if (self.event_fd == 0) {
                const event_fd = linux.eventfd(0, linux.EFD_NONBLOCK | linux.EFD_CLOEXEC);
                switch (linux.getErrno(event_fd)) {
                    0 => self.event_fd = @intCast(Handle, event_fd),
                    os.EMFILE, os.ENFILE, os.ENODEV, os.ENOMEM => return zio.Event.Poller.SendError.OutOfResources,
                    os.EINVAL => unreachable,
                    else => unreachable,
                }
                try self.epoll_ctl(self.event_fd, linux.EPOLL_CTL_ADD, zio.Event.Readable | zio.Event.EdgeTrigger, ~usize(0));
            }

            var value = @intCast(u64, data);
            const errno = linux.getErrno(linux.write(self.event_fd, @ptrCast([*]u8, &value), @sizeOf(@typeOf(value))));
            if (errno != 0)
                return os.unexpectedErrno(errno);
        }

        pub fn poll(self: *@This(), events: []Event, timeout: ?u32) zio.Event.Poller.PollError![]Event {
            const timeout_ms = if (timeout) |t| @intCast(i32, t) else -1;
            const events_ptr = @ptrCast([*]linux.epoll_event, events.ptr);
            while (true) {
                const events_found = linux.epoll_wait(self.epoll_fd, events_ptr, @intCast(u32, events.len), timeout_ms);
                switch (linux.getErrno(events_found)) {
                    0 => return events[0..events_found],
                    os.EBADF, os.EINVAL => return zio.Event.Poller.PollError.InvalidHandle,
                    os.EFAULT => return zio.Event.Poller.PollError.InvalidEvents,
                    os.EINTR => continue,
                    else => unreachable,
                }
            }
        }

        fn epoll_ctl(self: @This(), handle: Handle, op: u32, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            var event = linux.epoll_event {
                .data = linux.epoll_data { .ptr = data },
                .events = 0,
            };

            if ((flags & zio.Event.Writeable) != 0)
                event.events |= linux.EPOLLOUT; 
            if ((flags & zio.Event.Readable) != 0)
                event.events |= linux.EPOLLIN | linux.EPOLLRDHUP;
            if ((flags & zio.Event.EdgeTrigger) != 0) {
                event.events |= linux.EPOLLET;
            } else {
                event.events |= linux.EPOLLONESHOT;
            }

            return switch (linux.getErrno(linux.epoll_ctl(self.epoll_fd, op, handle, &event))) {
                0 => {},
                os.EBADF, os.EINVAL, os.ELOOP, os.ENOENT, os.EPERM => zio.Event.Poller.RegisterError.InvalidValue,
                os.ENOMEM, os.ENOSPC => zio.Event.Poller.RegisterError.OutOfResources,
                else => unreachable,
            };
        }
    };
};

pub const Socket = struct {
    pub usingnamespace posix.BsdSocket;

    pub fn isReadable(self: *const @This(), event: Event) bool {
        return (event.inner.events & linux.EPOLLIN) != 0;
    }

    pub fn isWriteable(self: *const @This(), event: Event) bool {
        return (event.inner.events & linux.EPOLLOUT) != 0;
    }
};
