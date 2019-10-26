const std = @import("std");
const linux = std.os.linux;

const zell = @import("../../../zap.zig").zell;
const zio = @import("../../../zap.zig").zio;
const Task = zell.runtime.Task;

pub const Reactor = struct {
    inner: Backend,

    const Backend = union(enum) {
        Epoll: EpollReactor,
        Uring: UringReactor,
    };

    pub fn init(self: *@This()) zell.Reactor.InitError!void {
        var major: usize = undefined;
        var minor: usize = undefined;
        getKernelVersion(&major, &minor) catch return self.initEpoll();
        if (major >= 5 and minor >= 1)
            return self.initUring();
        return self.initEpoll();
    }

    fn getKernelVersion(major: *usize, minor: *usize) !void {
        var uts: linux.utsname = undefined;
        if (linux.getErrno(linux.uname(&uts)) != 0)
            return error.uname;
        const sep = try std.mem.indexOf(uts.release[2..], ".");
        major.* = try std.fmt.parseInt(usize, uts.release[0..1], 10);
        minor.* = try std.fmt.parseInt(usize, uts.release[2 .. 2 + sep], 10);
    }

    fn initEpoll(self: *@This()) zell.Reactor.InitError!void {
        self.inner = Backend{ .Epoll = undefined };
        return self.inner.Epoll.init();
    }

    fn initUring(self: *@This()) zell.Reactor.InitError!void {
        self.inner = Backend{ .Uring = undefined };
        return self.inner.Uring.init();
    }

    pub fn deinit(self: *@This()) void {
        return switch (self.inner) {
            .Epoll => |*epoll| epoll.deinit(),
            .Uring => |*uring| uring.deinit(),
        };
    }

    pub fn notify(self: *@This()) zell.Reactor.NotifyError!void {
        return switch (self.inner) {
            .Epoll => |*epoll| epoll.notify(),
            .Uring => |*uring| uring.notify(),
        };
    }

    pub fn open(self: *@This(), path: []const u8, flags: u32) zell.Reactor.OpenError!zio.Handle {
        return switch (self.inner) {
            .Epoll => |*epoll| epoll.open(path, flags),
            .Uring => |*uring| uring.open(path, flags),
        };
    }

    pub fn fsync(self: *@This(), handle: zio.Handle, flags: u32) zell.Reactor.FsyncError!void {
        return switch (self.inner) {
            .Epoll => |*epoll| epoll.fsync(handle, flags),
            .Uring => |*uring| uring.fsync(handle, flags),
        };
    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) zell.Reactor.SocketError!zio.Handle {
        return switch (self.inner) {
            .Epoll => |*epoll| epoll.socket(flags),
            .Uring => |*uring| uring.socket(flags),
        };
    }

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {
        return switch (self.inner) {
            .Epoll => |*epoll| epoll.close(handle),
            .Uring => |*uring| uring.close(handle),
        };
    }

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) zell.Reactor.ConnectError!void {
        return switch (self.inner) {
            .Epoll => |*epoll| epoll.connect(handle, address),
            .Uring => |*uring| uring.connect(handle, address),
        };
    }

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) zell.Reactor.AcceptError!zio.Handle {
        return switch (self.inner) {
            .Epoll => |*epoll| epoll.accept(handle, address),
            .Uring => |*uring| uring.accept(handle, address),
        };
    }

    pub fn readv(self: *@This(), address: ?*zio.Address, buffer: []const []u8, offset: ?u64) zell.Reactor.ReadError!usize {
        return switch (self.inner) {
            .Epoll => |*epoll| epoll.readv(address, buffer, offset),
            .Uring => |*uring| uring.readv(address, buffer, offset),
        };
    }

    pub fn writev(self: *@This(), address: ?*zio.Address, buffer: []const []const u8, offset: ?u64) zell.Reactor.WriteError!usize {
        return switch (self.inner) {
            .Epoll => |*epoll| epoll.writev(address, buffer, offset),
            .Uring => |*uring| uring.writev(address, buffer, offset),
        };
    }

    pub fn poll(self: *@This(), timeout_ms: ?u32) zell.Reactor.PollError!Task.List {
        return switch (self.inner) {
            .Epoll => |*epoll| epoll.poll(),
            .Uring => |*uring| uring.deinit(),
        };
    }
};

const EpollReactor = struct {
    inner: zio.Event.Poller,

    pub fn init(self: *@This()) zell.Reactor.InitError!void {
        return self.inner.init();
    }

    pub fn deinit(self: *@This()) void {
        return self.inner.deinit();
    }

    pub fn notify(self: *@This()) zell.Reactor.NotifyError!void {
        return self.inner.notify(0);
    }

    pub fn open(self: *@This(), path: []const u8, flags: u32) zell.Reactor.OpenError!zio.Handle {
        @compileError("Unimplemented");
    }

    pub fn fsync(self: *@This(), handle: zio.Handle, flags: u32) zell.Reactor.FsyncError!void {
        @compileError("Unimplemented");
    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) zell.Reactor.SocketError!zio.Handle {}

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {}

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) zell.Reactor.ConnectError!void {}

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) zell.Reactor.AcceptError!zio.Handle {}

    pub fn readv(self: *@This(), address: ?*zio.Address, buffer: []const []u8, offset: ?u64) zell.Reactor.ReadError!usize {}

    pub fn writev(self: *@This(), address: ?*zio.Address, buffer: []const []const u8, offset: ?u64) zell.Reactor.WriteError!usize {}

    pub fn poll(self: *@This(), timeout_ms: ?u32) zell.Reactor.PollError!Task.List {}
};

const UringReactor = struct {
    pub fn init(self: *@This()) zell.Reactor.InitError!void {}

    pub fn deinit(self: *@This()) void {}

    pub fn notify(self: *@This()) zell.Reactor.NotifyError!void {}

    pub fn open(self: *@This(), path: []const u8, flags: u32) zell.Reactor.OpenError!zio.Handle {
        @compileError("Unimplemented");
    }

    pub fn fsync(self: *@This(), handle: zio.Handle, flags: u32) zell.Reactor.FsyncError!void {
        @compileError("Unimplemented");
    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) zell.Reactor.SocketError!zio.Handle {}

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {}

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) zell.Reactor.ConnectError!void {}

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) zell.Reactor.AcceptError!zio.Handle {}

    pub fn readv(self: *@This(), address: ?*zio.Address, buffer: []const []u8, offset: ?u64) zell.Reactor.ReadError!usize {}

    pub fn writev(self: *@This(), address: ?*zio.Address, buffer: []const []const u8, offset: ?u64) zell.Reactor.WriteError!usize {}

    pub fn poll(self: *@This(), timeout_ms: ?u32) zell.Reactor.PollError!Task.List {}
};

///-----------------------------------------------------------------------------///
///                                API Definitions                              ///
///-----------------------------------------------------------------------------///
const IORING_SETUP_IOPOLL = 1 << 0;
const IORING_SETUP_SQPOLL = 1 << 1;
const IORING_FEAT_SINGLE_MMAP = 1 << 0;

const IORING_ENTER_GETEVENTS = 1 << 0;
const IORING_ENTER_SQ_WAKEUP = 1 << 1;
const IORING_SQ_NEED_WAKEUP = 1 << 0;

const IORING_OFF_SQ_RING = 0;
const IORING_OFF_CQ_RING = 0x8000000;
const IORING_OFF_SQES = 0x10000000;

const IORING_OP_NOP = 0;
const IORING_OP_READV = 1;
const IORING_OP_WRITEV = 2;
const IORING_OP_FSYNC = 3;
const IORING_OP_READ_FIXED = 4;
const IORING_OP_WRITE_FIXED = 5;
const IORING_OP_POLL_ADD = 6;
const IORING_OP_POLL_REMOVE = 7;
const IORING_OP_SENDMSG = 9;
const IORING_OP_RECVMSG = 10;
const IORING_OP_ACCEPT = 13;

const io_uring_cqe = extern struct {
    user_data: u64,
    res: i32,
    flags: u32,
};

const io_uring_sqe = extern struct {
    opcode: u8,
    flags: u8,
    ioprio: u16,
    fd: i32,
    off_addr: u64,
    addr: u64,
    len: u32,
    op_flags: u32,
    user_data: u64,
    padding: [3]u64,
};

const io_uring_params = extern struct {
    sq_entries: u32,
    cq_entries: u32,
    flags: u32,
    sq_thread_cpu: u32,
    sq_thread_idle: u32,
    features: u32,
    resv: [4]u32,
    sq_off: io_sqring_offsets,
    cq_off: io_cqring_offsets,
};

const io_cqring_offsets = extern struct {
    head: u32,
    tail: u32,
    ring_mask: u32,
    ring_entries: u32,
    overflow: u32,
    cqes: u32,
    resv: [2]u64,
};

const io_sqring_offsets = extern struct {
    head: u32,
    tail: u32,
    ring_mask: u32,
    ring_entries: u32,
    flags: u32,
    dropped: u32,
    array: u32,
    resv1: u32,
    resv2: u64,
};
