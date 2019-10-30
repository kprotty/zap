const std = @import("std");
const builtin = @import("builtin");
const zio = @import("../../../zap.zig").zio;
const Task = @import("../runtime.zig").Task;
const Reactor = @import("../reactor.zig").Reactor;

pub const UringReactor = struct {
    const linux = std.os.linux;

    pub fn isSupported() bool {
        // TODO: Check kernel for 5.1 >=
        return false;
    }

    pub fn init(self: *@This(), allocator: *std.mem.Allocator) Reactor.Error!void {}

    pub fn deinit(self: *@This()) void {}

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) Reactor.SocketError!Reactor.TypedHandle {
        return Reactor.SocketError.OutOfResources;
    }

    pub fn close(self: *@This(), typed_handle: Reactor.TypedHandle) void {}

    pub fn getHandle(self: *@This(), typed_handle: Reactor.TypedHandle) zio.Handle {
        return zio.Handle(undefined);
    }

    pub fn accept(self: *@This(), typed_handle: Reactor.TypedHandle, flags: zio.Socket.Flags, address: *zio.Address) Reactor.AcceptError!Reactor.TypedHandle {
        return Reactor.AcceptError.InvalidHandle;
    }

    pub fn connect(self: *@This(), typed_handle: Reactor.TypedHandle, address: *const zio.Address) Reactor.ConnectError!void {
        return Reactor.ConnectError.InvalidHandle;
    }

    pub fn read(self: *@This(), typed_handle: Reactor.TypedHandle, address: ?*zio.Address, buffers: []const []u8, offset: ?u64) Reactor.ReadError!usize {
        return Reactor.ReadError.InvalidHandle;
    }

    pub fn write(self: *@This(), typed_handle: Reactor.TypedHandle, address: ?*const zio.Address, buffers: []const []const u8, offset: ?u64) Reactor.WriteError!usize {
        return Reactor.WriteError.InvalidHandle;
    }

    pub fn notify(self: *@This()) Reactor.NotifyError!void {
        return Reactor.NotifyError.InvalidHandle;
    }

    pub fn poll(self: *@This(), timeout_ms: ?u32) Reactor.PollError!Task.List {
        return Reactor.PollError.InvalidHandle;
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
