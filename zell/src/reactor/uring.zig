const std = @import("std");
const builtin = @import("builtin");
const zio = @import("../../../zap.zig").zio;
const zync = @import("../../../zap.zig").zync;
const Task = @import("../executor.zig").Task;
const Reactor = @import("../reactor.zig").Reactor;

pub const UringReactor = struct {
    const linux = std.os.linux;

    pub fn isSupported() bool {
        return false; // disable for now
    }

    fn _isSupported() bool {
        var uts: linux.utsname = undefined;
        if (linux.getErrno(linux.uname(&uts)) != 0)
            return false;

        // parse linux kernel version from uname
        var release = std.mem.toSliceConst(u8, &uts.release);
        const major_end = std.mem.indexOf(u8, release, ".") orelse return false;
        const major = std.fmt.parseInt(u32, release[0..major_end], 10) catch return false;
        release = release[major_end + 1 ..];
        const minor_end = std.mem.indexOf(u8, release, ".") orelse return false;
        const minor = std.fmt.parseInt(u32, release[0..minor_end], 10) catch return false;

        // io_uring is only supported on Linux kernel 5.1 >=
        return major >= 5 and minor >= 1;
    }

    ring_fd: zio.Handle,
    sq_memory: []u8,
    cq_memory: []u8,

    cq_mask: u32,
    cq_head_ptr: *zync.Atomic(u32),
    cq_tail_ptr: *const zync.Atomic(u32),

    sq_mask: u32,
    sq_flags: *const zync.Atomic(u32),
    sq_head_ptr: *zync.Atomic(u32),
    sq_tail_ptr: *const zync.Atomic(u32),
    sq_entries: []linux.io_uring_sqe,
    sq_active: zync.Atomic(usize),
    sq_waiting: zync.Atomic(?*Task),

    pub fn init(self: *@This(), allocator: *std.mem.Allocator) Reactor.Error!void {
        // setup the io_uring fd using SQPOLL to support less syscalls
        var params = zync.zeroed(linux.io_uring_params);
        const ring_fd = linux.io_uring_setup(4096, &params);
        switch (linux.getErrno(ring_fd)) {
            0 => self.ring_fd = @intCast(zio.Handle, ring_fd),
            linux.EFAULT, linux.EINVAL, linux.EPERM => unreachable,
            linux.ENFILE, linux.ENOMEM => return Reactor.Error.OutOfResources,
            else => unreachable,
        }
        errdefer {
            _ = linux.close(self.ring_fd);
        }

        // map the sqe structure array into process memory from the kernel
        const sqe_size = params.sq_entries * @sizeOf(linux.io_uring_sqe);
        const sqe_ptr = linux.mmap(null, sqe_size, linux.PROT_READ | linux.PROT_WRITE, linux.MAP_SHARED | linux.MAP_POPULATE, self.ring_fd, linux.IORING_OFF_SQES);
        if (linux.getErrno(sqe_ptr) != 0)
            return Reactor.Error.OutOfResources;

        // map the sqe index array into process memory from kernel
        const sq_size = params.sq_off.array + params.sq_entries * @sizeOf(u32);
        const sq_ptr = linux.mmap(null, sq_size, linux.PROT_READ | linux.PROT_WRITE, linux.MAP_SHARED | linux.MAP_POPULATE, self.ring_fd, linux.IORING_OFF_SQ_RING);
        if (linux.getErrno(sq_ptr) != 0)
            return Reactor.Error.OutOfResources;
        errdefer {
            _ = linux.munmap(@intToPtr([*]const u8, sq_ptr), sq_size);
        }

        // map the cqe structure array into process memory from the kernel
        const cq_size = params.cq_off.cqes + params.cq_entries * @sizeOf(linux.io_uring_cqe);
        const cq_ptr = linux.mmap(null, cq_size, linux.PROT_READ | linux.PROT_WRITE, linux.MAP_SHARED | linux.MAP_POPULATE, self.ring_fd, linux.IORING_OFF_CQ_RING);
        if (linux.getErrno(cq_ptr) != 0)
            return Reactor.Error.OutOfResources;
        errdefer {
            _ = linux.munmap(@intToPtr([*]const u8, cq_ptr), cq_size);
        }

        // setup completion fields
        self.cq_mask = @intToPtr(*const u32, sq_ptr + params.cq_off.ring_mask).*;
        self.cq_head_ptr = @intToPtr(*zync.Atomic(u32), cq_ptr + params.cq_off.head);
        self.cq_tail_ptr = @intToPtr(*const zync.Atomic(u32), cq_ptr + params.cq_off.tail);

        // setup submission fields
        self.sq_mask = @intToPtr(*const u32, sq_ptr + params.sq_off.ring_mask).*;
        self.sq_flags = @intToPtr(*const zync.Atomic(u32), sq_ptr + params.sq_off.flags);
        self.sq_head_ptr = @intToPtr(*zync.Atomic(u32), sq_ptr + params.sq_off.head);
        self.sq_tail_ptr = @intToPtr(*const zync.Atomic(u32), sq_ptr + params.sq_off.tail);
        self.sq_entries = @intToPtr([*]linux.io_uring_sqe, sqe_ptr)[0..params.sq_entries];
        self.sq_active.set(0);
    }

    pub fn deinit(self: *@This()) void {
        _ = linux.munmap(@ptrCast([*]u8, self.sq_entries.ptr), self.sq_entries.len * @sizeOf(linux.io_uring_sqe));
        _ = linux.munmap(self.sq_memory.ptr, self.sq_memory.len);
        _ = linux.munmap(self.cq_memory.ptr, self.cq_memory.len);
    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) Reactor.SocketError!Reactor.TypedHandle {
        const sock = try zio.Socket.new(flags | zio.Socket.Nonblock);
        return Reactor.TypedHandle{ .Socket = @intCast(usize, sock.getHandle()) };
    }

    pub fn close(self: *@This(), typed_handle: Reactor.TypedHandle) void {
        _ = linux.close(self.getHandle(typed_handle));
    }

    pub fn getHandle(self: *@This(), typed_handle: Reactor.TypedHandle) zio.Handle {
        return @intCast(zio.Handle, typed_handle.getValue());
    }

    pub fn accept(self: *@This(), typed_handle: Reactor.TypedHandle, flags: zio.Socket.Flags, address: *zio.Address) Reactor.AcceptError!Reactor.TypedHandle {
        return Reactor.AcceptError.OutOfResources;
    }

    pub fn _accept(self: *@This(), typed_handle: Reactor.TypedHandle, flags: zio.Socket.Flags, address: *zio.Address) Reactor.AcceptError!Reactor.TypedHandle {
        // TODO
        var incoming = zio.Address.Incoming.new(address.*);
        var sock = zio.Socket.fromHandle(self.getHandle(typed_handle), zio.Socket.Nonblock);
        _ = try self.polled(zio.Event.Readable, accept, zio.Socket.accept, &sock, flags | zio.Socket.Nonblock, &incoming);
        const client_sock = incoming.getSocket(flags | zio.Socket.Nonblock);
        return Reactor.TypedHandle{ .Socket = @intCast(usize, client_sock.getHandle()) };
    }

    pub fn connect(self: *@This(), typed_handle: Reactor.TypedHandle, address: *const zio.Address) Reactor.ConnectError!void {
        var sock = zio.Socket.fromHandle(self.getHandle(typed_handle), zio.Socket.Nonblock);
        return self.polled(zio.Event.Writeable, connect, zio.Socket.connect, &sock, address);
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

    fn polled(self: *@This(), comptime io_token: zio.Event.Flags, comptime caller: var, comptime func: var, args: ...) @typeOf(caller).ReturnType {
        return func(args, 0) catch |e| switch (e) {
            zio.Error.Closed => return error.Closed,
            zio.Error.InvalidToken => unreachable,
            zio.Error.Pending => {
                const sqe = self.getSubmission(linux.IORING_OP_POLL_ADD, args[0].getHandle(), 0, 0, 0);
                sqe.union1.poll_events = if (io_token == zio.Event.Readable) linux.POLLIN else linux.POLLOUT;
                sqe.union1.poll_events |= linux.POLLERR | linux.POLLHUP;
                self.submit(sqe);
                return func(args, io_token) catch |err| switch (err) {
                    zio.Error.Closed => return error.Closed,
                    zio.Error.InvalidToken => unreachable,
                    zio.Error.Pending => unreachable,
                    else => |raw_err| return raw_err,
                };
            },
            else => |raw_err| return raw_err,
        };
    }

    fn getSubmission(self: *@This(), op: u8, fd: zio.Handle, address: usize, length: usize, offset: u64) *linux.io_uring_sqe {
        return @intToPtr(*linux.io_uring_sqe, 1); // TODO;
    }

    fn submit(self: *@This(), sqe: *linux.io_uring_sqe) void {}
};
