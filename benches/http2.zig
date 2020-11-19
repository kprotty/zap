const std = @import("std");
const zap = @import("zap");

pub fn main() !void {
    try try zap.runtime.run(.{}, asyncMain, .{});
}

fn asyncMain() !void {
    var poller: Poller = undefined;
    try poller.init();
    defer poller.deinit();

    const sock_flags = std.os.SOCK_CLOEXEC | std.os.SOCK_NONBLOCK;
    const port: u16 = 9000;
    
    var server: Socket = undefined;
    try server.init(&poller, blk: {
        const fd = try std.os.socket(std.os.AF_INET, std.os.SOCK_STREAM | sock_flags, std.os.IPPROTO_TCP);
        errdefer std.os.close(fd);

        var addr = try std.net.Address.parseIp("127.0.0.1", port);
        try std.os.setsockopt(fd, std.os.SOL_SOCKET, std.os.SO_REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try std.os.bind(fd, &addr.any, addr.getOsSockLen());
        try std.os.listen(fd, 128);

        break :blk fd;
    });
    defer server.deinit();

    std.debug.warn("Listening on localhost:{}\n", .{port});
    while (true) {
        const fd = std.os.accept(server.fd, null, null, sock_flags) catch |err| switch (err) {
            error.WouldBlock => {
                try server.readers.wait(.{});
                continue;
            },
            else => |e| return e,
        };

        zap.runtime.spawn(.{}, Client.run, .{fd, &poller}) catch {
            std.os.close(fd);
            continue;
        };
    }
}

const Client = struct {
    socket: Socket,
    state: usize,

    fn run(fd: std.os.socket_t, poller: *Poller) void {
        var client: Client = undefined;
        client.state = 0;
        client.socket.init(poller, fd) catch return std.os.close(fd);
        defer client.socket.deinit();

        const SOL_TCP = 6;
        const TCP_NODELAY = 1;
        std.os.setsockopt(fd, SOL_TCP, TCP_NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch return;

        var write_frame = async client.runWriter();
        var read_frame = async client.runReader();

        (await write_frame) catch {};
        (await read_frame) catch {};
    }

    const HTTP_CLRF = "\r\n\r\n";
    const HTTP_RESPONSE = "HTTP/1.1 200 Ok\r\nContent-Length: 10\r\nContent-Type: text/plain; charset=utf8\r\nDate: Thu, 19 Nov 2020 14:26:34 GMT\r\nServer: fasthttp\r\n\r\nHelloWorld";

    fn runReader(self: *Client) !void {
        var length: usize = 0;
        var buffer: [4096]u8 = undefined;
        defer self.notify(true);

        while (true) {
            if (std.mem.indexOf(u8, buffer[0..length], HTTP_CLRF)) |consumed| {
                const remaining = buffer[(consumed + HTTP_CLRF.len)..length];
                if (remaining.len > 0)
                    @memcpy(&buffer, remaining.ptr, remaining.len);
                length = remaining.len;
                self.notify(false);
                continue;
            }

            const read_buf = buffer[length..];
            if (read_buf.len == 0)
                return error.RequestTooLarge;

            const transferred = blk: {
                while (true) {
                    const rc = std.os.read(self.socket.fd, read_buf);
                    zap.runtime.yield();
                    break :blk rc catch |err| switch (err) {
                        error.WouldBlock => {
                            try self.socket.readers.wait(.{});
                            continue;
                        },
                        else => |e| return e,
                    };
                }
            };

            length += transferred;
            if (transferred == 0)
                return error.EOF;
        }
    }

    fn runWriter(self: *Client) !void {
        const num_chunks = 128;
        const chunk = HTTP_RESPONSE ** num_chunks;

        const Writer = struct {
            fn write(client: *Client, buffer: []const u8) error{Bad}!usize {
                retry: while (true) {
                    const rc = std.os.send(client.socket.fd, buffer, std.os.MSG_NOSIGNAL);
                    return rc catch |err| switch (err) {
                        error.WouldBlock => {
                            client.socket.writers.wait(.{}) catch return error.Bad;
                            continue :retry;
                        },
                        else => return error.Bad,
                    };
                }
            }

            fn writer(client: *Client) std.io.Writer(*Client, error{Bad}, @This().write) {
                return .{ .context = client };
            }
        };

        while (true) {
            var responses = try self.wait();
            while (responses > 0) {
                const amount = std.math.min(num_chunks, responses);
                const buffer = chunk[0..(amount * HTTP_RESPONSE.len)];
                try Writer.writer(self).writeAll(buffer);
                responses -= amount;
            }
        }
    }

    const EMPTY: usize = 0;
    const WAITING: usize = 1;
    const NOTIFIED: usize = 2;
    const SHUTDOWN: usize = 3;

    const Waiter = struct {
        result: ?usize,
        task: zap.runtime.executor.Task,
    };

    fn wait(self: *Client) !usize {
        var waiter = Waiter{
            .result = null,
            .task = zap.runtime.executor.Task.init(@frame()),
        };

        suspend {
            var state = @atomicLoad(usize, &self.state, .Monotonic);
            while (true) {
                const new_state = switch (state & 0b11) {
                    EMPTY => @ptrToInt(&waiter) | WAITING,
                    WAITING => unreachable,
                    NOTIFIED => EMPTY,
                    SHUTDOWN => {
                        zap.runtime.schedule(&waiter.task, .{});
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
                    if (new_state == EMPTY) {
                        waiter.result = (state >> 2);
                        zap.runtime.schedule(&waiter.task, .{});
                    }
                    break;
                };
            }
        }

        return waiter.result orelse error.Closed;
    }

    fn notify(self: *Client, shutdown: bool) void {
        var state = @atomicLoad(usize, &self.state, .Monotonic);
        while (true) {
            const new_state = switch (state & 0b11) {
                EMPTY => if (shutdown) SHUTDOWN else NOTIFIED | (1 << 2),
                WAITING => if (shutdown) SHUTDOWN else EMPTY,
                NOTIFIED => if (shutdown) SHUTDOWN else state + (1 << 2),
                SHUTDOWN => unreachable,
                else => unreachable,
            };

            state = @cmpxchgWeak(
                usize,
                &self.state,
                state,
                new_state,
                .Acquire,
                .Monotonic,
            ) orelse {
                if ((state & 0b11) == WAITING) {
                    const waiter = @intToPtr(*Waiter, state & ~@as(usize, 0b11));
                    waiter.result = 1;
                    zap.runtime.schedule(&waiter.task, .{});
                }
                break;
            };
        }
    }
};

const Socket = struct {
    fd: std.os.socket_t,
    readers: Port = Port{},
    writers: Port = Port{},
    
    fn init(self: *Socket, poller: *Poller, fd: std.os.socket_t) !void {
        self.* = Socket{ .fd = fd };

        try std.os.epoll_ctl(poller.fd, std.os.EPOLL_CTL_ADD, self.fd, &std.os.epoll_event{
            .events = std.os.EPOLLIN | std.os.EPOLLOUT | std.os.EPOLLET | std.os.EPOLLRDHUP,
            .data = .{ .ptr = @ptrToInt(self) },
        });
    }

    fn deinit(self: *Socket) void {
        defer self.* = undefined;

        _ = std.os.linux.shutdown(self.fd, std.os.SHUT_RDWR);
        while (true) self.readers.wait(.{ .use_next = true }) catch break;
        while (true) self.writers.wait(.{ .use_next = true }) catch break;
        std.os.close(self.fd);
    }
};

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
            if (count == 0)
                continue;

            var batch = zap.runtime.executor.Batch{};
            defer if (!batch.isEmpty())
                self.scheduler.schedule(batch);

            for (events[0..count]) |event| {
                if (event.data.ptr == @ptrToInt(self)) 
                    return;

                const socket = @intToPtr(*Socket, event.data.ptr);
                const shutdown = event.events & (std.os.EPOLLERR | std.os.EPOLLHUP | std.os.EPOLLRDHUP) != 0;

                if (shutdown or (event.events & std.os.EPOLLOUT != 0)) {
                    if (socket.writers.notify(shutdown)) |task|
                        batch.push(task);
                }

                if (shutdown or (event.events & std.os.EPOLLIN != 0)) {
                    if (socket.readers.notify(shutdown)) |task|
                        batch.push(task);
                }
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
};

const Port = struct {
    state: usize = EMPTY,

    const EMPTY: usize = 0;
    const NOTIFIED: usize = 1;
    const SHUTDOWN: usize = 2;
    const WAITING: usize = ~(EMPTY | NOTIFIED | SHUTDOWN);

    const Waiter = struct {
        is_shutdown: bool align(std.math.max(~WAITING + 1, @alignOf(usize))),
        task: zap.runtime.executor.Task,
    };

    fn wait(self: *Port, hints: zap.runtime.executor.Worker.ScheduleHints) !void {
        var waiter = Waiter{
            .is_shutdown = false,
            .task = zap.runtime.executor.Task.init(@frame()),
        };

        suspend {
            var state = @atomicLoad(usize, &self.state, .Monotonic);
            while (true) {
                const new_state = switch (state) {
                    EMPTY => @ptrToInt(&waiter),
                    NOTIFIED => EMPTY,
                    SHUTDOWN => {
                        waiter.is_shutdown = true;
                        zap.runtime.schedule(&waiter.task, .{ .use_next = true });
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
                        zap.runtime.schedule(&waiter.task, hints);
                    break;
                };
            }
        }

        if (waiter.is_shutdown)
            return error.Closed;
    }

    fn notify(self: *Port, shutdown: bool) ?*zap.runtime.executor.Task {
        var state = @atomicLoad(usize, &self.state, .Monotonic);
        while (true) {
            const new_state = switch (state) {
                EMPTY => if (shutdown) SHUTDOWN else NOTIFIED,
                NOTIFIED => return null,
                SHUTDOWN => return null,
                else => if (shutdown) SHUTDOWN else EMPTY,
            };

            state = @cmpxchgWeak(
                usize,
                &self.state,
                state,
                new_state,
                .Acquire,
                .Monotonic,
            ) orelse {
                const waiter = @intToPtr(?*Waiter, state & WAITING) orelse return null;
                waiter.is_shutdown = shutdown;
                return &waiter.task;
            };
        }
    }
};