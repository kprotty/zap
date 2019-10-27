const std = @import("std");
const posix = @import("posix.zig");

const Task = @import("../runtime.zig").Task;
const zio = @import("../../../zap.zig").zio;
const zell = @import("../../../zap.zig").zell;

pub const Poller = struct {
    inner: Inner,

    const Inner = union(enum) {
        Uring: UringPoller,
        Default: posix.Poller,
    };

    pub fn init(self: *@This(), allocator: *std.mem.Allocator) zell.Poller.Error!void {
        if (UringPoller.isSupported()) {
            self.inner = Inner { .Uring = undefined };
            return self.inner.Uring.init(allocator);
        } else {
            self.inner = Inner { .Default = undefined };
            return self.inner.Default.init(allocator);
        }
    }

    pub fn deinit(self: *@This()) void {
        return switch (self.inner) {
            .Uring => |*uring| uring.deinit(),
            .Default => |*default| default.deinit(),
        };
    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) zell.Poller.SocketError!zio.Handle {
        return switch (self.inner) {
            .Uring => |*uring| uring.socket(flags),
            .Default => |*default| default.socket(flags),
        };
    }

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {
        return switch (self.inner) {
            .Uring => |*uring| uring.close(handle, is_socket),
            .Default => |*default| default.close(handle, is_socket),
        };
    }

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) zell.Poller.ConnectError!void {
        return switch (self.inner) {
            .Uring => |*uring| uring.connect(handle, address),
            .Default => |*default| default.connect(handle, address),
        };
    }

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) zell.Poller.AcceptError!zio.Handle {
        return switch (self.inner) {
            .Uring => |*uring| uring.accept(handle, address),
            .Default => |*default| default.accept(handle, address),
        };
    }

    pub fn read(self: *@This(), handle: zio.Handle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) zell.Poller.ReadError!usize {
        return switch (self.inner) {
            .Uring => |*uring| uring.read(handle, address, buffer, offset),
            .Default => |*default| default.read(handle, address, buffer, offset),
        };
    }

    pub fn write(self: *@This(), handle: zio.Handle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) zell.Poller.WriteError!usize {
        return switch (self.inner) {
            .Uring => |*uring| uring.write(handle, address, buffer, offset),
            .Default => |*default| default.write(handle, address, buffer, offset),
        };
    }

    pub fn poll(self: *@This(), timeout_ms: u32) zell.Poller.PollError!Task.List {
        return switch (self.inner) {
            .Uring => |*uring| uring.poll(timeout_ms),
            .Default => |*default| default.poll(timeout_ms),
        };
    }
};

const UringPoller = struct {
    pub fn init(self: *@This(), allocator: *std.mem.Allocator) zell.Poller.Error!void {
        
    }

    pub fn deinit(self: *@This()) void {

    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) zell.Poller.SocketError!zio.Handle {

    }

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {

    }

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) zell.Poller.ConnectError!void {
        
    }

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) zell.Poller.AcceptError!zio.Handle {
        
    }

    pub fn read(self: *@This(), handle: zio.Handle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) zell.Poller.ReadError!usize {

    }

    pub fn write(self: *@This(), handle: zio.Handle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) zell.Poller.WriteError!usize {
        
    }

    pub fn poll(self: *@This(), timeout_ms: u32) zell.Poller.PollError!Task.List {

    }

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
};
