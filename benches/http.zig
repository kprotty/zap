const std = @import("std");
const zap = @import("zap");

pub fn main() !void {
    try try zap.runtime.run(.{}, asyncMain, .{});
}

fn asyncMain() !void {
    const allocator = std.heap.c_allocator;
    const port = 8080;

    var io_driver: IoDriver = undefined;
    try io_driver.init(zap.runtime.getWorker().getScheduler());
    defer io_driver.deinit();

    const server_fd = blk: {
        const fd = try std.os.socket(
            std.os.AF_INET, 
            std.os.SOCK_STREAM | std.os.SOCK_NONBLOCK | std.os.SOCK_CLOEXEC,
            std.os.IPPROTO_TCP,
        );
        var addr = try std.net.Address.parseIp("127.0.0.1", port);
        try std.os.setsockopt(fd, std.os.SOL_SOCKET, std.os.SO_REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try std.os.bind(fd, &addr.any, addr.getOsSockLen());
        try std.os.listen(fd, 128);
        break :blk fd;
    };

    var server = Socket{ .fd = server_fd };
    try server.init(&io_driver);
    defer server.deinit();

    std.debug.warn("Listening on localhost:{}\n", .{port});
    while (true) {

        const client_fd = try server.call(&server.readers, std.os.accept, .{
            server.fd,
            null,
            null,
            std.os.SOCK_CLOEXEC | std.os.SOCK_NONBLOCK,
        });

        zap.runtime.spawn(
            .{ .allocator = allocator },
            Client.run,
            .{ client_fd, &io_driver, allocator },
        ) catch std.os.close(client_fd);
    }
}

const Client = struct {
    socket: Socket,
    counter: Counter = Counter{},
    allocator: *std.mem.Allocator,

    fn run(fd: std.os.fd_t, io_driver: *IoDriver, allocator: *std.mem.Allocator) void {
        var client = Client{
            .socket = Socket{ .fd = fd },
            .allocator = allocator,
        };

        client.socket.init(io_driver) catch return;
        defer client.socket.deinit();

        var read_frame = async client.reader();
        var write_frame = async client.writer();

        (await read_frame) catch {};
        (await write_frame) catch {};
    }

    fn writer(self: *Client) !void {
        zap.runtime.yield();

        const num_chunks = 1024;
        const resp = "HTTP/1.1 200 Ok\r\nContent-Length: 11\r\n\r\nHello World";
        const chunked = resp ** num_chunks;

        var responses: usize = 0;
        while (true) {
            var partial: usize = 0;
            var bytes: usize = resp.len * responses;

            while (bytes > 0) {
                var iovecs = [1]std.os.iovec_const{.{
                    .iov_base = @ptrCast([*]const u8, &chunked[0]) + partial,
                    .iov_len = std.math.min(bytes, num_chunks * resp.len),
                }};

                var msghdr = std.mem.zeroes(std.os.msghdr_const);
                msghdr.msg_iov = &iovecs;
                msghdr.msg_iovlen = 1;

                const rc = std.os.linux.sendmsg(self.socket.fd, &msghdr, std.os.MSG_NOSIGNAL);
                const sent = switch (std.os.linux.getErrno(rc)) {
                    0 => rc,
                    std.os.EACCES => return error.AccessDenied,
                    std.os.EAGAIN => return error.WouldBlock,
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

                partial = sent % resp.len;
                bytes -= sent;
            }            

            responses = try self.counter.wait();
        }
    }

    fn reader(self: *Client) !void {
        zap.runtime.yield();

        var frame_buf: [1024]u8 = undefined;
        var buf_len: usize = 0;
        var buf: []u8 = &frame_buf;
        var buf_alloc = false;

        defer if (buf_alloc) self.allocator.free(buf);
        defer self.counter.shutdown();

        var requests: usize = 0;
        while (true) {
            const clrf = "\r\n\r\n";
            const req_end = std.mem.indexOf(u8, buf[0..buf_len], clrf) orelse {

                const empty = buf.len - buf_len;
                if (empty < buf.len / 2) {
                    const new_buf = try self.allocator.alloc(u8, buf.len * 2);
                    std.mem.copy(u8, new_buf, buf[0..buf_len]);
                    if (buf_alloc) {
                        self.allocator.free(buf);
                    } else {
                        buf_alloc = true;
                    }
                    buf = new_buf;
                }

                const bytes = blk: {
                    self.counter.notify(requests);
                    requests = 0;
                    retry: while (true) {
                        break :blk std.os.read(self.socket.fd, buf[buf_len..]) catch |err| switch (err) {
                            error.WouldBlock => {
                                self.socket.readers.wait() catch |e| return e;
                                continue :retry;
                            },
                            else => |e| return e,
                        };
                    }
                };

                if (bytes == 0) return;
                buf_len += bytes;
                continue;
            };

            const req = req_end + clrf.len;
            std.mem.copy(u8, buf, buf[req..buf_len]);
            buf_len -= req;
            requests += 1;
        }
    }

    const Counter = struct {
        state: usize = 0,

        const WAITING: usize = 1;
        const SHUTDOWN: usize = 2;

        const Waiter = struct {
            is_closed: bool,
            responses: usize,
            task: zap.runtime.executor.Task,
        };

        fn wait(self: *Counter) !usize {
            var waiter: Waiter = undefined;
            waiter.responses = 0;
            waiter.is_closed = false;
            waiter.task = @TypeOf(waiter.task).init(@frame());

            while (true) {
                if (waiter.is_closed)
                    return error.Closed;
                if (waiter.responses > 0)
                    return waiter.responses;

                suspend {
                    var state = @atomicLoad(usize, &self.state, .Monotonic);
                    while (true) {
                        waiter.is_closed = state & SHUTDOWN != 0;
                        if (waiter.is_closed) {
                            zap.runtime.schedule(&waiter.task, .{ .use_lifo = true });
                            break;
                        }
                        
                        if (state & WAITING != 0)
                            unreachable;

                        waiter.responses = state >> 2;
                        const new_state = if (waiter.responses == 0) @ptrToInt(&waiter) | WAITING else 0;
                        if (@cmpxchgWeak(
                            usize,
                            &self.state,
                            state,
                            new_state,
                            .Release,
                            .Monotonic,
                        )) |updated| {
                            state = updated;
                            continue;
                        }

                        if (waiter.responses > 0)
                            zap.runtime.schedule(&waiter.task, .{ .use_lifo = true });
                        break;
                    }
                }
            }
        }

        fn notify(self: *Counter, responses: usize) void {
            var state = @atomicLoad(usize, &self.state, .Monotonic);
            while (true) {
                if (state & SHUTDOWN != 0)
                    return;

                const new_state = if (state & WAITING != 0) 0 else (state + (responses << 2));
                if (@cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    new_state,
                    .Acquire,
                    .Monotonic,
                )) |updated| {
                    state = updated;
                    continue;
                }

                if (state & WAITING != 0) {
                    const waiter = @intToPtr(*Waiter, state & ~@as(usize, 0b11));
                    waiter.responses = responses;
                    zap.runtime.schedule(&waiter.task, .{ .use_lifo = true });
                }

                return;
            }
        }

        fn shutdown(self: *Counter) void {
            const state = @atomicRmw(usize, &self.state, .Xchg, SHUTDOWN, .AcqRel);
            if (state & WAITING != 0) {
                const waiter = @intToPtr(*Waiter, state & ~@as(usize, 0b11));
                waiter.is_closed = true;
                zap.runtime.schedule(&waiter.task, .{ .use_lifo = true });
            }
        }
    };
};

const Socket = struct {
    fd: std.os.socket_t,
    readers: Port = Port{},
    writers: Port = Port{},

    fn init(self: *Socket, io_driver: *IoDriver) !void {
        try std.os.epoll_ctl(io_driver.efd, std.os.EPOLL_CTL_ADD, self.fd, &std.os.epoll_event{
            .events = std.os.EPOLLIN | std.os.EPOLLOUT | std.os.EPOLLERR | std.os.EPOLLHUP | std.os.EPOLLET,
            .data = .{ .ptr = @ptrToInt(self) },
        });
    }

    fn deinit(self: *Socket) void {
        std.os.close(self.fd);
        while (true) self.readers.wait() catch break;
        while (true) self.writers.wait() catch break;
    }

    fn read(self: *Socket, buffer: []u8) !usize {
        return self.call(&self.readers, std.os.recv, .{self.fd, buffer, 0});
    }

    fn reader(self: *Socket) std.io.Reader(*Socket, ErrorUnionOf(Socket.read).error_set, Socket.read) {
        return .{ .context = self };
    }

    fn write(self: *Socket, buffer: []const u8) !usize {
        return self.call(&self.writers, std.os.send, .{self.fd, buffer, std.os.MSG_NOSIGNAL});
    }

    fn writer(self: *Socket) std.io.Writer(*Socket, ErrorUnionOf(Socket.write).error_set, Socket.write) {
        return .{ .context = self };
    }

    fn ErrorUnionOf(comptime func: anytype) std.builtin.TypeInfo.ErrorUnion {
        return @typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?).ErrorUnion;
    }

    fn call(
        self: *Socket,
        port: *Port,
        comptime func: anytype,
        args: anytype,
    ) !ErrorUnionOf(func).payload {
        retry: while (true) {
            return @call(.{}, func, args) catch |err| switch (err) {
                error.WouldBlock => {
                    port.wait() catch |e| return e;
                    continue :retry;
                },
                else => |e| return e,
            };
        }
    }

    const Port = struct {
        state: usize = EMPTY,

        const EMPTY: usize = 0;
        const NOTIFIED: usize = 1;
        const SHUTDOWN: usize = 2;
        const WAITING: usize = ~(NOTIFIED | SHUTDOWN);

        const Waiter = struct {
            is_shutdown: bool,
            task: zap.runtime.executor.Task,
        };

        fn wait(self: *Port) !void {
            var waiter: Waiter = undefined;
            waiter.is_shutdown = false;
            waiter.task = @TypeOf(waiter.task).init(@frame());

            suspend {
                var state = @atomicLoad(usize, &self.state, .Monotonic);
                while (true) {
                    const new_state = switch (state) {
                        EMPTY => @ptrToInt(&waiter),
                        NOTIFIED => EMPTY,
                        SHUTDOWN => {
                            waiter.is_shutdown = true;
                            zap.runtime.schedule(&waiter.task, .{ .use_lifo = true });
                            break;
                        },
                        else => unreachable,
                    };
                    state = @cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        new_state,
                        .Release,
                        .Monotonic,
                    ) orelse {
                        if (new_state == EMPTY)
                            zap.runtime.schedule(&waiter.task, .{ .use_lifo = true });
                        break;
                    };
                }
            }

            if (waiter.is_shutdown)
                return error.Closed;
        }

        fn notify(self: *Port) ?*zap.runtime.executor.Task {
            var state = @atomicLoad(usize, &self.state, .Monotonic);
            while (true) {
                const new_state = switch (state) {
                    EMPTY => NOTIFIED,
                    NOTIFIED, SHUTDOWN => return null,
                    else => EMPTY,
                };
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    new_state,
                    .Acquire,
                    .Monotonic,
                ) orelse {
                    if (new_state == NOTIFIED)
                        return null;
                    const waiter = @intToPtr(*Waiter, state);
                    return &waiter.task;
                };
            }
        }

        fn shutdown(self: *Port) ?*zap.runtime.executor.Task {
            return switch (@atomicRmw(usize, &self.state, .Xchg, SHUTDOWN, .AcqRel)) {
                EMPTY, NOTIFIED, SHUTDOWN => null,
                else => |state| {
                    const waiter = @intToPtr(*Waiter, state);
                    waiter.is_shutdown = false;
                    return &waiter.task;
                }
            };
        }
    };
};

const IoDriver = struct {
    efd: std.os.fd_t,
    evfd: std.os.fd_t,
    thread: *std.Thread,
    scheduler: *zap.runtime.executor.Scheduler,

    fn init(self: *IoDriver, scheduler: *zap.runtime.executor.Scheduler) !void {
        self.efd = try std.os.epoll_create1(std.os.EPOLL_CLOEXEC);
        errdefer std.os.close(self.efd);

        self.evfd = try std.os.eventfd(0, std.os.EFD_CLOEXEC | std.os.EFD_NONBLOCK);
        errdefer std.os.close(self.evfd);
        try std.os.epoll_ctl(self.efd, std.os.EPOLL_CTL_ADD, self.evfd, &std.os.epoll_event{
            .events = std.os.EPOLLIN | std.os.EPOLLERR | std.os.EPOLLHUP | std.os.EPOLLONESHOT,
            .data = .{ .ptr = @ptrToInt(self) },
        });

        self.scheduler = scheduler;
        self.thread = try std.Thread.spawn(self, @This().run);
    }

    fn deinit(self: *IoDriver) void {
        _ = std.os.write(self.evfd, std.mem.asBytes(&@as(u64, 1))) catch unreachable;
        self.thread.wait();
        
        std.os.close(self.evfd);
        std.os.close(self.efd);
    }

    fn run(self: *IoDriver) void {
        var events: [128]std.os.epoll_event = undefined;

        while (true) {
            const count = std.os.epoll_wait(self.efd, &events, -1);
            if (count == 0) continue;

            var batch = zap.runtime.executor.Batch{};
            defer self.scheduler.schedule(batch);

            for (events[0..count]) |event| {
                if (event.data.ptr == @ptrToInt(self))
                    return;
                
                const socket = @intToPtr(*Socket, event.data.ptr);
                if (event.events & (std.os.EPOLLERR | std.os.EPOLLHUP) != 0) {
                    if (socket.writers.shutdown()) |task|
                        batch.push(task);
                    if (socket.readers.shutdown()) |task|
                        batch.push(task);
                } else {
                    if (event.events & std.os.EPOLLOUT != 0) {
                        if (socket.writers.notify()) |task|
                            batch.push(task);
                    }
                    if (event.events & std.os.EPOLLIN != 0) {
                        if (socket.readers.notify()) |task|
                            batch.push(task);
                    }
                }
            }
        }
    }
};