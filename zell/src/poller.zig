const std = @import("std");
const builtin = @import("builtin");
const zio = @import("../../zap.zig").zio;
const zync = @import("../../zap.zig").zync;
const zuma = @import("../../zap.zig").zuma;
const Task = @import("../runtime.zig").Task;

pub const Poller = struct {
    pub const Handle = usize;
    pub const TypedHandle = union(enum) {
        Socket: Handle,
    };

    inner: Inner,
    const Inner = union(enum) {
        Default: DefaultPoller,
        Uring: if (builtin.os == .linux) UringPoller else void,
    };

    pub const Error = zio.Event.Poller.Error;

    pub fn init(self: *@This(), allocator: *std.mem.Allocator) Error!void {
        if (builtin.os == .linux and UringPoller.isSupported()) {
            self.inner = Inner{ .Uring = undefined };
            return self.inner.Uring.init(allocator);
        } else {
            self.inner = Inner{ .Default = undefined };
            return self.inner.Default.init(allocator);
        }
    }

    pub fn deinit(self: *@This()) void {
        return switch (self.inner) {
            .Uring => |*uring| uring.deinit(),
            .Default => |*default| default.deinit(),
        };
    }

    pub const SocketError = zio.Socket.Error || zio.Event.Poller.RegisterError;

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) SocketError!Handle {
        return switch (self.inner) {
            .Uring => |*uring| uring.socket(flags),
            .Default => |*default| default.socket(flags),
        };
    }

    pub fn close(self: *@This(), typed_handle: TypedHandle) void {
        return switch (self.inner) {
            .Uring => |*uring| uring.close(typed_handle),
            .Default => |*default| default.close(typed_handle),
        };
    }

    pub const ConnectError = zio.Socket.RawConnectError || error{Closed};

    pub fn connect(self: *@This(), handle: Handle, address: *const zio.Address) ConnectError!void {
        return switch (self.inner) {
            .Uring => |*uring| uring.connect(handle, address),
            .Default => |*default| default.connect(handle, address),
        };
    }

    pub const AcceptError = zio.Socket.RawAcceptError || error{Closed};

    pub fn accept(self: *@This(), handle: Handle, address: *zio.Address) AcceptError!Handle {
        return switch (self.inner) {
            .Uring => |*uring| uring.accept(handle, address),
            .Default => |*default| default.accept(handle, address),
        };
    }

    pub const ReadError = zio.Socket.RawDataError || error{Closed};

    pub fn read(self: *@This(), handle: Handle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) ReadError!usize {
        return switch (self.inner) {
            .Uring => |*uring| uring.read(handle, address, buffer, offset),
            .Default => |*default| default.read(handle, address, buffer, offset),
        };
    }

    pub const WriteError = zio.Socket.RawDataError || error{Closed};

    pub fn write(self: *@This(), handle: Handle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) WriteError!usize {
        return switch (self.inner) {
            .Uring => |*uring| uring.write(handle, address, buffer, offset),
            .Default => |*default| default.write(handle, address, buffer, offset),
        };
    }

    pub const NotifyError = zio.Event.Poller.NotifyError;

    pub fn notify(self: *@This()) NotifyError!void {
        return switch (self.inner) {
            .Uring => |*uring| uring.notify(),
            .Default => |*default| default.notify(),
        };
    }

    pub const PollError = zio.Event.Poller.PollError;

    pub fn poll(self: *@This(), timeout_ms: u32) PollError!Task.List {
        return switch (self.inner) {
            .Uring => |*uring| uring.poll(timeout_ms),
            .Default => |*default| default.poll(timeout_ms),
        };
    }
};

const DefaultPoller = struct {
    inner: zio.Event.Poller,
    cache: Descriptor.Cache,

    pub fn init(self: *@This(), allocator: *std.mem.Allocator) Poller.Error!void {
        try self.inner.init();
        self.cache.init(allocator);
    }

    pub fn deinit(self: *@This()) void {
        self.cache.deinit();
        self.inner.close();
    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) Poller.SocketError!Poller.Handle {
        const sock = try zio.Socket.new(flags | zio.Socket.Nonblock);
        const descriptor = self.cache.alloc(sock.getHandle()) orelse return Poller.SocketError.OutOfResources;
        const event_flags = zio.Event.Readable | zio.Event.Writeable | zio.Event.EdgeTrigger;
        try self.inner.register(sock.getHandle(), event_flags, @ptrToInt(descriptor));
        return @ptrToInt(descriptor);
    }

    pub fn close(self: *@This(), typed_handle: TypedHandle) void {
        return switch (typed_handle) {
            .Socket => |handle| zio.Socket.fromHandle(handle).close(),
        };
    }

    pub fn connect(self: *@This(), handle: Poller.Handle, address: *const zio.Address) Poller.ConnectError!void {}

    pub fn accept(self: *@This(), handle: Poller.Handle, address: *zio.Address) Poller.AcceptError!Poller.Handle {}

    pub fn read(self: *@This(), handle: Poller.Handle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) Poller.ReadError!usize {}

    pub fn write(self: *@This(), handle: Poller.Handle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) Poller.WriteError!usize {}

    pub fn notify(self: *@This()) Poller.NotifyError!void {}

    pub fn poll(self: *@This(), timeout_ms: u32) Poller.PollError!Task.List {}

    const Descriptor = struct {
        token: usize,
        reader: ?*Task,
        writer: ?*Task,
        handle: zio.Handle align(@alignOf(usize)),

        pub fn next(self: *const @This()) *?*@This() {
            return @ptrCast(*?*@This(), &self.reader);
        }

        pub const Cache = struct {
            mutex: zync.Mutex,
            chunk_head: ?*Chunk,
            chunk_tail: ?*Chunk,
            free_chunk: ?*Chunk,
            free_list: ?*Descriptor,
            allocator: *std.mem.Allocator,

            pub fn init(self: *@This(), allocator: *std.mem.Allocator) void {
                self.mutex.init();
                self.free_list = null;
                self.free_chunk = null;
                self.chunk_head = null;
                self.chunk_tail = null;
                self.allocator = allocator;
            }

            pub fn deinit(self: *@This()) void {
                self.mutex.deinit();
            }

            pub fn alloc(self: *@This()) ?*Descriptor {
                self.mutex.acquire();
                defer self.mutex.release();

                if (self.free_list) |descriptor| {
                    self.free_list = descriptor.next().*;
                    return descriptor;
                }
            }

            pub fn free(self: *@This(), descriptor: *Descriptor) void {
                self.mutex.acquire();
                defer self.mutex.release();
            }
        };

        pub fn getChunk(self: *const @This()) *Chunk {
            comptime {
                std.debug.assert(zync.nextPowerOfTwo(Chunk.PageSize) == Chunk.PageSize);
                std.debug.assert(@alignOf(Chunk) == Chunk.PageSize);
            }
            return @intToPtr(*Chunk, @ptrToInt(self) & ~usize(Chunk.PageSize - 1));
        }

        const Chunk = struct {
            pub const PageSize = std.math.max(64 * 1024, zuma.page_size);
            descriptors: [PageSize / @sizeOf(Descriptor)]Descriptor align(PageSize),

            pub fn size(self: *@This()) *usize {
                return @ptrCast(*usize, &self.descriptors[0].token);
            }

            pub fn next(self: *@This()) *?*@This() {
                return @ptrCast(*?*@This(), &self.descriptors[0].reader);
            }

            pub fn prev(self: *@This()) *?*@This() {
                return @ptrCast(*?*@This(), &self.descriptors[0].writer);
            }

            pub fn cache(self: *const @This()) *Cache {
                return @ptrCast(*const *Cache, &self.descriptors[0].handle).*;
            }
        };
    };
};

const UringPoller = struct {
    const linux = std.os.linux;

    pub fn init(self: *@This(), allocator: *std.mem.Allocator) Poller.Error!void {}

    pub fn deinit(self: *@This()) void {}

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) Poller.SocketError!Poller.Handle {}

    pub fn close(self: *@This(), typed_handle: TypedHandle) void {}

    pub fn connect(self: *@This(), handle: Poller.Handle, address: *const zio.Address) Poller.ConnectError!void {}

    pub fn accept(self: *@This(), handle: Poller.Handle, address: *zio.Address) Poller.AcceptError!Poller.Handle {}

    pub fn read(self: *@This(), handle: Poller.Handle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) Poller.ReadError!usize {}

    pub fn write(self: *@This(), handle: Poller.Handle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) Poller.WriteError!usize {}

    pub fn notify(self: *@This()) Poller.NotifyError!void {}

    pub fn poll(self: *@This(), timeout_ms: u32) Poller.PollError!Task.List {}

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
