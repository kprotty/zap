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
    socket: Socket = undefined,
    allocator: *std.mem.Allocator,
    process_chan: Channel([PROC_BUF_LEN][]u8) = Channel([PROC_BUF_LEN][]u8){},
    write_chan: Channel([WRITE_BUF_LEN][]const u8) = Channel([WRITE_BUF_LEN][]const u8){},

    const PROC_BUF_LEN = 32;
    const WRITE_BUF_LEN = 64;

    fn run(fd: std.os.socket_t, poller: *Poller) void {
        var client = Client{ .allocator = zap.runtime.getWorker().getAllocator() };
        client.socket.init(poller, fd) catch return std.os.close(fd);
        defer client.socket.deinit();

        const SOL_TCP = 6;
        const TCP_NODELAY = 1;
        std.os.setsockopt(fd, SOL_TCP, TCP_NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch return;

        var read_frame = async client.runReader();
        var process_frame = async client.runProcessor();
        var write_frame = async client.runWriter();

        (await read_frame) catch {};
        (await process_frame) catch {};
        (await write_frame) catch {};
    }

    const HTTP_RESPONSE = "HTTP/1.1 200 Ok\r\nContent-Length: 11\r\n\r\nHello World";

    fn runReader(self: *Client) !void {
        zap.runtime.yield();

        defer self.process_chan.close();

        while (true) {
            var read_len: usize = 0;
            var read_buf: [16 * 1024]u8 = undefined;

            do_read: while (true) {
                const read = std.os.read(self.socket.fd, read_buf[read_len..]) catch |err| switch (err) {
                    error.WouldBlock => {
                        if (read_len > 0) {
                            const buf = try self.allocator.alloc(u8, read_len);
                            errdefer self.allocator.free(buf);
                            @memcpy(buf.ptr, &read_buf, read_len);
                            try self.process_chan.push(buf);
                        }
                        zap.runtime.yield();
                        try self.socket.readers.wait(.{});
                        break :do_read;
                    },
                    else => |e| return e,
                };

                if (read == 0)
                    return error.Eof;
                read_len += read;
            }
        }
    }

    fn runProcessor(self: *Client) !void {
        zap.runtime.yield();

        defer self.write_chan.close();
        defer {
            self.process_chan.close();
            while (true) {
                const buf = (self.process_chan.tryPop() catch break) orelse break;
                self.allocator.free(buf);
            }
        }

        var req_len: usize = 0;
        var req_buf: [16 * 1024]u8 = undefined;

        while (true) {
            var remain = req_buf[req_len..];
            const buf = try self.process_chan.pop();
            if (remain.len < buf.len)
                return error.RequestTooLarge;

            @memcpy(remain.ptr, buf.ptr, buf.len);
            req_len += buf.len;
            self.allocator.free(buf);

            var consumed: usize = 0;
            while (std.mem.indexOf(u8, req_buf[consumed..req_len], "\r\n\r\n")) |end| {
                try self.write_chan.push(HTTP_RESPONSE);
                consumed += end + 4;
            }

            remain = req_buf[consumed..req_len];
            @memcpy(&req_buf, remain.ptr, remain.len);
            req_len = remain.len;
            zap.runtime.yield();
        }
    }

    fn runWriter(self: *Client) !void {
        zap.runtime.yield();

        defer self.write_chan.close();

        const Writer = struct {
            fn write(client: *Client, buffer: []const u8) error{Bad}!usize {
                retry: while (true) {
                    return std.os.send(client.socket.fd, buffer, std.os.MSG_NOSIGNAL) catch |err| switch (err) {
                        error.WouldBlock => {
                            client.socket.writers.wait(.{}) catch return error.Bad;
                            continue :retry;
                        },
                        else => return error.Bad,
                    };
                }
            }
        };

        var send_len: usize = 0;
        const send_buf = HTTP_RESPONSE ** 256;
        var writer: std.io.Writer(*Client, error{Bad}, Writer.write) = .{ .context = self };

        while (true) {
            while (send_len < send_buf.len) {
                _ = (try self.write_chan.tryPop()) orelse break;
                send_len += HTTP_RESPONSE.len;
            }

            if (send_len > 0) {
                try writer.writeAll(send_buf[0..send_len]);
                send_len = 0;
                continue;
            }

            _ = try self.write_chan.pop();
            send_len = HTTP_RESPONSE.len;
        }
    }
};

fn Channel(comptime Buffer: type) type {
    return struct {
        lock: std.Mutex = std.Mutex{},
        buffer: Buffer = undefined,
        head: usize = 0,
        tail: usize = 0,
        closed: bool = false,
        readers: ?*Waiter = null,
        writers: ?*Waiter = null,

        const Self = @This();
        const T = @typeInfo(Buffer).Array.child;
        const Waiter = struct {
            next: ?*Waiter,
            tail: *Waiter,
            item: error{Closed}!T,
            task: zap.runtime.executor.Task,
        };

        pub fn close(self: *Self) void {
            const held = self.lock.acquire();

            if (self.closed) {
                held.release();
                return;
            }

            var readers = self.readers;
            var writers = self.writers;
            self.readers = null;
            self.writers = null;
            self.closed = true;
            held.release();

            var batch = zap.runtime.executor.Batch{};
            defer zap.runtime.schedule(batch, .{});

            while (readers) |waiter| {
                waiter.item = error.Closed;
                batch.push(&waiter.task);
                readers = waiter.next;
            }
            while (writers) |waiter| {
                waiter.item = error.Closed;
                batch.push(&waiter.task);
                writers = waiter.next;
            }
        }

        pub fn push(self: *Self, item: T) !void {
            const held = self.lock.acquire();

            if (self.closed) {
                held.release();
                return error.Closed;
            }

            if (self.readers) |reader| {
                const waiter = reader;
                self.readers = waiter.next;
                held.release();

                waiter.item = item;
                zap.runtime.schedule(&waiter.task, .{});
                return;
            }

            if (self.tail -% self.head < self.buffer.len) {
                self.buffer[self.tail % self.buffer.len] = item;
                self.tail +%= 1;
                held.release();
                return;
            }

            var waiter: Waiter = undefined;
            waiter.next = null;
            if (self.writers) |head| {
                head.tail.next = &waiter;
                head.tail = &waiter;
            } else {
                self.writers = &waiter;
                waiter.tail = &waiter;
            }

            suspend {
                waiter.item = item;
                waiter.task = @TypeOf(waiter.task).init(@frame());
                held.release();
            }

            _ = try waiter.item;
        }

        pub fn tryPop(self: *Self) !?T {
            const held = self.lock.acquire();

            if (self.writers) |writer| {
                const waiter = writer;
                self.writers = waiter.next;
                held.release();

                const item = writer.item catch unreachable;
                zap.runtime.schedule(&waiter.task, .{});
                return item;
            }

            if (self.tail != self.head) {
                const item = self.buffer[self.head % self.buffer.len];
                self.head +%= 1;
                held.release();
                return item;
            }

            const closed = self.closed;
            held.release();
            if (closed)
                return error.Closed;
            return null;
        }

        pub fn pop(self: *Self) !T {
            const held = self.lock.acquire();

            if (self.writers) |writer| {
                const waiter = writer;
                self.writers = waiter.next;
                held.release();

                const item = writer.item catch unreachable;
                zap.runtime.schedule(&waiter.task, .{});
                return item;
            }

            if (self.tail != self.head) {
                const item = self.buffer[self.head % self.buffer.len];
                self.head +%= 1;
                held.release();
                return item;
            }

            if (self.closed) {
                held.release();
                return error.Closed;
            }

            var waiter: Waiter = undefined;
            waiter.next = null;
            if (self.readers) |head| {
                head.tail.next = &waiter;
                head.tail = &waiter;
            } else {
                self.readers = &waiter;
                waiter.tail = &waiter;
            }

            suspend {
                waiter.item = undefined;
                waiter.task = @TypeOf(waiter.task).init(@frame());
                held.release();
            }

            return (try waiter.item);
        }
    };
}

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
        while (true) self.readers.wait(.{ .use_lifo = true }) catch break;
        while (true) self.writers.wait(.{ .use_lifo = true }) catch break;
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