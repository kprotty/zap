const std = @import("std");
const zap = @import("zap");

pub fn main() !void {
    try try zap.runtime.run(.{}, asyncMain, .{});
}

fn asyncMain() !void {
    const allocator = std.heap.c_allocator;

    var notify: Notify = undefined;
    try notify.init(zap.runtime.executor.Worker.getCurrent().?.getScheduler());
    defer notify.deinit();

    const sfd = try std.os.socket(std.os.AF_INET, std.os.SOCK_STREAM | std.os.SOCK_NONBLOCK | std.os.SOCK_CLOEXEC, std.os.IPPROTO_TCP);
    var server = Socket.init(sfd, &notify);
    defer server.deinit();

    var addr = try std.net.Address.parseIp("127.0.0.1", 8080);
    try std.os.setsockopt(sfd, std.os.SOL_SOCKET, std.os.SO_REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try std.os.bind(sfd, &addr.any, addr.getOsSockLen());
    try std.os.listen(sfd, 128);

    while (true) {
        const cfd = try server.call(true, std.os.accept, .{sfd, null, null, std.os.SOCK_NONBLOCK | std.os.SOCK_CLOEXEC});
        const socket = Socket.init(cfd, &notify);
        zap.runtime.spawn(
            .{ .allocator = allocator },
            handleClient,
            .{ socket, allocator },
        ) catch std.os.close(cfd);
    }
}

fn handleClient(sock: Socket, allocator: *std.mem.Allocator) void {
    handleHttpClient(sock, allocator) catch {};
}

fn handleHttpClient(sock: Socket, allocator: *std.mem.Allocator) !void {
    var socket = sock;
    var frame_buf: [2048]u8 = undefined;

    var buf_len: usize = 0;
    var buf: []u8 = &frame_buf;
    var buf_alloc = false;
    defer if (buf_alloc) allocator.free(buf);

    while (true) {
        while (true) {
            const clrf = "\r\n\r\n";
            const request_end = std.mem.indexOf(u8, buf[0..buf_len], clrf) orelse {

                var empty = buf.len - buf_len;
                if (empty < buf.len / 2) {
                    const new_buf = try allocator.alloc(u8, buf.len * 2);
                    std.mem.copy(u8, new_buf, buf[0..buf_len]);
                    if (buf_alloc) {
                        allocator.free(buf);
                    } else {
                        buf_alloc = true;
                    }
                    buf = new_buf;
                }

                // std.debug.warn("empty req at {}\n", .{buf_len});

                const bytes = try socket.read(buf[buf_len..]);
                if (bytes == 0) return;
                buf_len += bytes;
                continue;
            };

            const req = request_end + clrf.len;
            // std.debug.warn("consumed {}/{}\n", .{req, buf_len});
            std.mem.copy(u8, buf, buf[req..buf_len]);
            buf_len -= req;

            try socket.writer().writeAll("HTTP/1.1 200 Ok\r\nContent-Length: 11\r\n\r\nHello World");
            break;
        }
    }
}

const Socket = struct {
    notify: *Notify,
    fd: std.os.socket_t,
    is_registered: bool = false,
    task: zap.runtime.executor.Task = undefined,

    fn init(fd: std.os.socket_t, notify: *Notify) Socket {
        return Socket{ .notify = notify, .fd = fd };
    }

    fn deinit(self: *Socket) void {
        if (!self.is_registered) {
            std.os.close(self.fd);
            return;
        }

        suspend {
            self.task = @TypeOf(self.task).init(@frame());
            if (std.os.epoll_ctl(self.notify.efd, std.os.EPOLL_CTL_MOD, self.fd, &std.os.epoll_event{
                .events = std.os.EPOLLERR | std.os.EPOLLHUP | std.os.EPOLLONESHOT,
                .data = .{ .ptr = @ptrToInt(&self.task) },
            })) |_| {
                std.os.close(self.fd);
            } else |_| {
                zap.runtime.schedule(&self.task, .{});
            }   
        }
    }

    fn ReturnErrorUnionOf(comptime func: anytype) std.builtin.TypeInfo.ErrorUnion {
        return @typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?).ErrorUnion;
    }

    fn ErrorSetOf(comptime func: anytype) type {
        return ReturnErrorUnionOf(func).error_set;
    }

    fn call(self: *Socket, is_read: bool, comptime func: anytype, args: anytype) !ReturnErrorUnionOf(func).payload {
        retry: while (true) {
            return @call(.{}, func, args) catch |err| switch (err) {
                error.WouldBlock => {
                    var ctl_err: ?std.os.EpollCtlError = null; 
                    suspend {
                        const op: u32 = if (self.is_registered) std.os.EPOLL_CTL_MOD else std.os.EPOLL_CTL_ADD;
                        const ev: u32 = if (is_read) std.os.EPOLLIN else std.os.EPOLLOUT;
                        self.is_registered = true;
                        self.task = @TypeOf(self.task).init(@frame());
                        std.os.epoll_ctl(self.notify.efd, op, self.fd, &std.os.epoll_event{
                            .events = ev | std.os.EPOLLERR | std.os.EPOLLHUP | std.os.EPOLLONESHOT,
                            .data = .{ .ptr = @ptrToInt(&self.task) },
                        }) catch |epoll_err| {
                            ctl_err = epoll_err;
                            self.is_registered = false;
                            zap.runtime.schedule(&self.task, .{ .use_lifo = true });
                        };
                    }
                    if (ctl_err) |e| return e;
                    continue :retry;
                },
                else => |e| return e,
            };
        }
    }

    fn reader(self: *Socket) std.io.Reader(*Socket, ErrorSetOf(Socket.read), Socket.read) {
        return .{ .context = self };
    }

    fn read(self: *Socket, buf: []u8) !usize {
        return self.call(true, std.os.recv, .{self.fd, buf, 0});
    }

    fn writer(self: *Socket) std.io.Writer(*Socket, ErrorSetOf(Socket.write), Socket.write) {
        return .{ .context = self };
    }

    fn write(self: *Socket, buf: []const u8) !usize {
        return self.call(false, std.os.send, .{self.fd, buf, std.os.MSG_NOSIGNAL});
    }
};

const Notify = struct {
    efd: std.os.fd_t,
    evfd: std.os.fd_t,
    thread: *std.Thread,
    scheduler: *zap.runtime.executor.Scheduler,

    fn init(self: *Notify, scheduler: *zap.runtime.executor.Scheduler) !void {
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

    fn deinit(self: *Notify) void {
        _ = std.os.write(self.evfd, std.mem.asBytes(&@as(u64, 1))) catch unreachable;
        self.thread.wait();
        
        std.os.close(self.evfd);
        std.os.close(self.efd);
    }

    fn run(self: *Notify) void {
        var events: [128]std.os.epoll_event = undefined;

        while (true) {
            const found = blk: {
                while (true) {
                    const rc = std.os.linux.epoll_wait(self.efd, &events, @intCast(u32, events.len), -1);
                    switch (std.os.linux.getErrno(rc)) {
                        0 => break :blk @intCast(usize, rc),
                        std.os.EINTR => continue,
                        else => return,
                    }
                }
            };

            if (found == 0) continue;
            var batch = zap.runtime.executor.Batch{};
            defer self.scheduler.schedule(batch);

            for (events[0..found]) |ev| {
                if (ev.data.ptr == 0) continue;
                if (ev.data.ptr == @ptrToInt(self)) return;
                const task = @intToPtr(*zap.runtime.executor.Task, ev.data.ptr);
                batch.push(task);
            }
        }
    }
};