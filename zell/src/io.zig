const std = @import("std");
const builtin = @import("builtin");

const Task = @import("runtime.zig").Task;
const zio = @import("../../zap.zig").zio;

const os = std.os;
const expect = std.testing.expect;

pub const Backend = struct {
    inner: Inner,

    pub const Inner = switch (builtin.os) {
        .linux => Linux,
        .windows => Iocp,
        else => Kqueue,
    };

    pub const InitError = error {

    };

    pub fn init(self: *@This()) InitError!void {
        return self.inner.init();
    }

    pub fn deinit(self: *@This()) void {
        return self.inner.deinit();
    }

    pub const OpenError = error {

    };

    pub fn open(self: *@This(), path: []const u8, flags: u32) OpenError!zio.Handle {
        return self.inner.open(path, flags);
    }

    pub const FsyncError = error {

    };

    pub fn fsync(self: *@This(), handle: zio.Handle, flags: u32) FsyncError!void {
        return self.inner.fsync(handle, flags);
    }

    pub const SocketError = error {

    };

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) SocketError!zio.Handle {
        return self.inner.socket(flags);
    }

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {
        return self.inner.close(handle, is_socket);
    }

    pub const ConnectError = error {

    };

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) ConnectError!void {
        return self.inner.connect(handle, address);
    }

    pub const AcceptError = error {

    };

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) AcceptError!zio.Handle {
        return self.inner.accept(handle, address);
    }

    pub const ReadError = error {

    };

    pub fn readv(self: *@This(), address: ?*zio.Address, buffer: []const []u8, offset: ?u64) ReadError!usize {
        return self.inner.readv(address, buffer, offset);
    }

    pub const WriteError = error {

    };

    pub fn writev(self: *@This(), address: ?*zio.Address, buffer: []const []const u8, offset: ?u64) WriteError!usize {
        return self.inner.writev(address, buffer, offset);
    }

    pub const PollError = error {

    };

    pub fn poll(self: *@This(), timeout_ms: ?u32) PollError!Task.List {
        return self.inner.poll(timeout_ms);
    }
};

const Linux = struct {
    const linux = std.os.linux;

    fd: u32,

    fn getHandle(self: @This()) zio.Handle {
        return @bitCast(i32, self.fd & (~u32(0) - 1));
    }

    fn is_epoll(self: @This()) bool {
        return (self.fd & (1 << 31)) == 1;
    }

    pub fn init(self: *@This()) Backend.InitError!void {
        // Get the kernel version
        var uts: linux.utsname = undefined;
        if (linux.getErrno(linux.uname(&uts)) != 0)
            return self.initEpoll();
        const version = uts.release[0..];

        // Check if the system is running Linux 5.1 >= to use io_uring
        const sep = std.mem.indexOf(uts.release[2..], ".") catch return self.initEpoll();
        const major = std.fmt.parseInt(usize, uts.release[0..1], 10) catch return self.initEpoll();
        const minor = std.fmt.parseInt(usize, uts.release[2..2 + sep], 10) catch return self.initEpoll();
        if (major >= 5 and minor >= 1)
            return self.initUring();
        return self.initEpoll();
    }

    fn initEpoll(self: *@This()) Backend.InitError!void {
        const fd = linux.epoll_create1(linux.EPOLL_CLOEXEC);
        return switch (linux.getErrno(fd)) {
            0 => self.fd = @intCast(u32, fd) | (1 << 31),
            linux.EMFILE, linux.ENOMEM => Backend.InitError.OutOfResources,
            linux.EINVAL => unreachable,
            else => unreachable,
        };
    }

    fn initUring(self: *@This()) Backend.InitError!void {

    }

    pub fn deinit(self: *@This()) void {
        if (!self.is_epoll()) {

        }
        _ = linux.close(self.getHandle());
    }

    pub fn open(self: *@This(), path: []const u8, flags: u32) Backend.OpenError!zio.Handle {

    }

    pub fn fsync(self: *@This(), handle: zio.Handle, flags: u32) Backend.FsyncError!void {

    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) Backend.SocketError!zio.Handle {

    }

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {

    }

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) Backend.ConnectError!void {

    }

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) Backend.AcceptError!zio.Handle {

    }

    pub fn readv(self: *@This(), address: ?*zio.Address, buffer: []const []u8, offset: ?u64) Backend.ReadError!usize {
        
    }

    pub fn writev(self: *@This(), address: ?*zio.Address, buffer: []const []const u8, offset: ?u64) Backend.WriteError!usize {

    }

    pub fn poll(self: *@This(), timeout_ms: ?u32) Backend.PollError!Task.List {

    }
};