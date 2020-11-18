const std = @import("std");
const zap = @import("zap");

pub fn main() !void {
    try try zap.runtime.run(.{}, asyncMain, .{});
}

fn asyncMain() !void {
    var poller: Poller = undefined;
    try poller.init();
    defer poller.deinit();

    try Server.run(9000, &poller);
}

const Poller = struct {
    fd: std.os.fd_t,
    notify_fd: std.os.fd_t,
    thread: *std.Thread,
    scheduler: *zap.runtime.executor.Scheduler,

    fn init(self: *Poller) !void {
        self.fd = try std.os.epoll_create1(std.os.EPOLL_CLOEXEC);
        errdefer std.os.close(self.fd);

        self.notify_fd = try std.os.eventfd(0, std.os.EFD_CLOEXEC | std.os.EFD_NONBLOCK);
        errdefer std.os.close(self.notify_fd);
        try std.os.epoll_ctl(self.fd, std.os.EPOLL_CTL_ADD, self.notify_fd, &std.os.epoll_event{
            .events = std.os.EPOLLIN | std.os.EPOLLERR | std.os.EPOLLHUP | std.os.EPOLLONESHOT,
            .data = .{ .ptr = @ptrToInt(self) },
        });

        self.scheduler = zap.runtime.getWorker().getScheduler();
        self.thread = try std.Thread.spawn(self, Poller.run);
    }

    fn run(self: *Poller) void {
        var events: [128]std.os.epoll_event = undefined;
        while (true) {
            const count = std.os.epoll_wait(self.fd, &events, -1);
            if (count == 0) continue;

            var batch = zap.runtime.executor.Batch{};
            defer if (!batch.isEmpty())
                self.scheduler.schedule(batch);

            for (events[0..count]) |event| {
                if (event.data.ptr == @ptrToInt(self)) return;
                batch.push(@intToPtr(*zap.runtime.executor.Task, event.data.ptr));
            }
        }
    }

    fn deinit(self: *Poller) void {
        _ = std.os.write(self.notify_fd, std.mem.asBytes(&@as(u64, 1))) catch unreachable;
        self.thread.wait();

        std.os.close(self.notify_fd);
        std.os.close(self.fd);
        self.* = undefined;
    }

    const Socket = struct {
        fd: std.os.socket_t,
        poller: *Poller,
        is_registered: bool = false,

        fn wait(self: *Socket, read: bool, write: bool) !void {
            var err: ?std.os.EpollCtlError = null;
            var task = zap.runtime.executor.Task.init(@frame());

            suspend {
                var op: u32 = std.os.EPOLL_CTL_ADD;
                if (self.is_registered)
                    op = std.os.EPOLL_CTL_MOD;
                
                var events: u32 = std.os.EPOLLERR | std.os.EPOLLHUP | std.os.EPOLLONESHOT;
                if (read) events |= std.os.EPOLLIN;
                if (write) events |= std.os.EPOLLOUT;

                self.is_registered = true;
                std.os.epoll_ctl(self.poller.fd, op, self.fd, &std.os.epoll_event{
                    .events = events,
                    .data = .{ .ptr = @ptrToInt(&task) },
                }) catch |ctl_err| {
                    err = ctl_err;
                    self.is_registered = false;
                    zap.runtime.schedule(&task, .{ .use_lifo = true });
                };
            }

            if (err) |e|
                return e;
        }
    };
};

const Server = struct {
    fn run(port: u16, poller: *Poller) !void {
        const flags = std.os.SOCK_NONBLOCK | std.os.SOCK_CLOEXEC;
        const server_fd = try std.os.socket(
            std.os.AF_INET, 
            std.os.SOCK_STREAM | flags,
            std.os.IPPROTO_TCP,
        );
        defer std.os.close(server_fd);
        var addr = try std.net.Address.parseIp("127.0.0.1", port);
        try std.os.setsockopt(server_fd, std.os.SOL_SOCKET, std.os.SO_REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try std.os.bind(server_fd, &addr.any, addr.getOsSockLen());
        try std.os.listen(server_fd, 128);

        var event = Poller.Socket{
            .fd = server_fd,
            .poller = poller,
        };

        std.debug.warn("Listening on 127.0.0.1:{}\n", .{port});
        while (true) {
            const client_fd = std.os.accept(server_fd, null, null, flags) catch |err| switch (err) {
                error.WouldBlock => {
                    try event.wait(true, false);
                    continue;
                },
                else => |e| return e,
            };

            zap.runtime.spawn(.{}, Client.run, .{client_fd, poller}) catch {
                std.os.close(client_fd);
                continue;
            };
        }
    }
};

const Client = struct {
    write_bytes: usize = 0,
    write_partial: usize = 0,
    read_len: usize = 0,
    read_buffer: [4096]u8 = undefined,
    socket: Poller.Socket,

    const HTTP_CLRF = "\r\n\r\n";
    const HTTP_RESPONSE = "HTTP/1.1 200 Ok\r\nContent-Length: 11" ++ HTTP_CLRF ++ "Hello World";

    fn run(fd: std.os.socket_t, poller: *Poller) void {
        defer std.os.close(fd);

        var self = Client{
            .socket = Poller.Socket{
                .fd = fd,
                .poller = poller,
            },
        };

        while (true) {
            var wait_for_write = self.writer() catch break;
            const wait_for_read = self.reader() catch break;
            
            if (!wait_for_write and self.write_bytes > 0)
                wait_for_write = self.writer() catch break;

            self.socket.wait(wait_for_read, wait_for_write) catch break;
        }
    }

    fn reader(self: *Client) !bool {
        while (true) {
            const request_buffer = self.read_buffer[0..self.read_len];
            const request_end = blk: {
                break :blk std.mem.indexOf(u8, request_buffer, HTTP_CLRF);
            };

            if (request_end) |end| {
                const remaining = self.read_buffer[(end + HTTP_CLRF.len)..self.read_len];
                @memcpy(&self.read_buffer, remaining.ptr, remaining.len);
                self.read_len = remaining.len;
                self.write_bytes += HTTP_RESPONSE.len;
                continue;
            }

            const read_buffer = self.read_buffer[self.read_len..];
            if (read_buffer.len == 0)
                return error.RequestTooLarge;

            const read = std.os.read(self.socket.fd, read_buffer) catch |err| switch (err) {
                error.WouldBlock => return true,
                else => |e| return e,
            };

            if (read == 0)
                return error.EOF;
            self.read_len += read;
        }
    }

    fn writer(self: *Client) !bool {
        const num_chunks = 256;
        const chunk = HTTP_RESPONSE ** num_chunks;

        while (true) {
            if (self.write_bytes == 0) {
                return false;
            }

            var iovecs = [1]std.os.iovec_const{.{
                .iov_base = @ptrCast([*]const u8, &chunk[0]) + self.write_partial,
                .iov_len = std.math.min(self.write_bytes, num_chunks * HTTP_RESPONSE.len),
            }};

            var msghdr = std.mem.zeroes(std.os.msghdr_const);
            msghdr.msg_iov = &iovecs;
            msghdr.msg_iovlen = 1;

            const rc = std.os.linux.sendmsg(self.socket.fd, &msghdr, std.os.MSG_NOSIGNAL);
            const sent = switch (std.os.linux.getErrno(rc)) {
                0 => rc,
                std.os.EACCES => return error.AccessDenied,
                std.os.EAGAIN => return true,
                std.os.EALREADY => return error.FastOpenAlreadyInProgress,
                std.os.EBADF => unreachable, // always a race condition
                std.os.ECONNRESET => return error.ConnectionResetByPeer,
                std.os.EDESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
                std.os.EFAULT => unreachable, // An invalid user space address was specified for an argument.
                std.os.EINTR => continue,
                std.os.EINVAL => unreachable, // Invalid argument passed.
                std.os.EISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
                std.os.EMSGSIZE => return error.MessageTooBig,
                std.os.ENOBUFS => return error.SystemResources,
                std.os.ENOMEM => return error.SystemResources,
                std.os.ENOTCONN => unreachable, // The socket is not connected, and no target has been given.
                std.os.ENOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
                std.os.EOPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
                std.os.EPIPE => return error.BrokenPipe,
                else => |err| return std.os.unexpectedErrno(err),
            };

            self.write_partial = sent % HTTP_RESPONSE.len;
            self.write_bytes -= sent;
        }
    }    
};