const std = @import("std");
const builtin = @import("builtin");

const Task = @import("runtime.zig").Task;
const zio = @import("../../zap.zig").zio;
const zync = @import("../../zap.zig").zync;
const zuma = @import("../../zap.zig").zuma;

const os = std.os;
const expect = std.testing.expect;

pub const Reactor = struct {
    inner: Inner,

    const Inner = union(enum) {
        Uring: if (builtin.os == .linux) UringReactor else void,
        Default: if (builtin.os == .windows) CompletionReactor else PolledReactor,
    };

    pub fn init(self: *@This(), allocator: *std.mem.Allocator) !void {
        if (builtin.os == .linux and UringReactor.isSupported()) {
            self.inner = Inner { .Uring = undefined };
            return self.inner.Uring.init();
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

    pub fn notify(self: *@This()) !void {
        return switch (self.inner) {
            .Uring => |*uring| uring.notify(),
            .Default => |*default| default.notify(),
        };
    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) !zio.Handle {
        return switch (self.inner) {
            .Uring => |*uring| uring.socket(flags),
            .Default => |*default| default.socket(flags),
        };
    }

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {
        return switch (self.inner) {
            .Uring => |*uring| uring.close(handle),
            .Default => |*default| default.close(handle, is_socket),
        };
    }

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) !void {
        return switch (self.inner) {
            .Uring => |*uring| uring.connect(handle, address),
            .Default => |*default| default.connect(handle, address),
        };
    }

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) !zio.Handle {
        return switch (self.inner) {
            .Uring => |*uring| uring.accept(handle, address),
            .Default => |*default| default.deinit(handle, address),
        };
    }

    pub fn read(self: *@This(), handle: zio.Handle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) !usize {
        return switch (self.inner) {
            .Uring => |*uring| uring.read(handle, address, buffer, offset),
            .Default => |*default| default.read(handle, address, buffer, offset),
        };
    }

    pub fn write(self: *@This(), handle: zio.Handle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) !usize {
        return switch (self.inner) {
            .Uring => |*uring| uring.write(handle, address, buffer, offset),
            .Default => |*default| default.write(handle, address, buffer, offset),
        };
    }

    pub fn poll(self: *@This(), timeout_ms: ?u32) !Task.List {
        return switch (self.inner) {
            .Uring => |*uring| uring.poll(timeout_ms),
            .Default => |*default| default.poll(timeout_ms),
        };
    }
};

const CompletionReactor = struct {
    poller: zio.Event.Poller,

    pub fn init(self: *@This(), allocator: *std.mem.Allocator) !void {}

    pub fn deinit(self: *@This()) void {}

    pub fn notify(self: *@This()) !void {}

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) !zio.Handle {}

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {}

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) !void {}

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) !zio.Handle {}

    pub fn readv(self: *@This(), handle: zio.Handle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) !usize {}

    pub fn writev(self: *@This(), handle: zio.Handle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) !usize {}

    pub fn poll(self: *@This(), timeout_ms: ?u32) !Task.List {}
};

const PolledReactor = struct {
    poller: zio.Event.Poller,
    channel_cache: Channel.Cache,
    
    pub fn init(self: *@This(), allocator: *std.mem.Allocator) !void {
        try self.poller.init();
        try self.channel_cache.init(allocator);
    }

    pub fn deinit(self: *@This()) void {
        self.poller.deinit();
        self.channel_cache.deinit();
    }

    pub fn notify(self: *@This()) !void {
        return self.poller.notify(0);
    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) !zio.Handle {}

    pub fn close(self: *@This(), handle: zio.Handle, is_socket: bool) void {}

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) !void {}

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) !zio.Handle {}

    pub fn readv(self: *@This(), handle: zio.Handle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) !usize {}

    pub fn writev(self: *@This(), handle: zio.Handle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) !usize {}

    pub fn poll(self: *@This(), timeout_ms: ?u32) !Task.List {}

    const Channel = struct {
        reader: ?*Task,
        writer: ?*Task,

        pub fn next(self: @This(), comptime Ptr: type) Ptr {
            return @ptrCast(Ptr, @alignCast(@alignOf(Ptr), self.reader));
        }

        pub fn prev(self: @This(), comptime Ptr: type) Ptr {
            return @ptrCast(Ptr, @alignCast(@alignOf(Ptr), self.writer));
        }

        pub const Cache = struct {
            mutex: zync.Mutex,
            top_chunk: ?*Chunk,
            free_list: ?*Channel,
            allocator: *std.mem.Allocator,

            pub fn init(self: *@This, allocator: *std.mem.Allocator) {
                self.mutex.init();
                self.top_chunk = null;
                self.free_list = null;
                self.allocator = allocator;
            }

            pub fn deinit(self: *@This()) void {
                self.mutex.acquire();
                defer self.mutex.release();
                defer self.mutex.deinit();

                while (self.top_chunk) |chunk| {
                    self.top_chunk = chunk.prev().*;
                    self.allocator.destroy(chunk);
                }
            }

            pub fn alloc(self: *@This()) ?*Channel {
                self.mutex.acquire();
                defer self.mutex.release();

                if (self.free_list) |channel| {
                    self.free_list = channel.next(?*Channel);
                    return channel;
                }
            }

            pub fn free(self: *@This(), channel: *Channel) {

            }
        };

        const Chunk = struct {
            channels: [zuma.page_size / @sizeOf(Channel)]Channel align(zuma.page_size),

            pub fn 
        };
    };
};

const UringReactor = struct {
    const linux = std.os.linux;

    pub fn isSupported() bool {
        // io_uring is only supported on linux kernel 5.1 and higher
        var uts: linux.utsname = undefined;
        if (linux.getErrno(linux.uname(&uts)) != 0)
            return false;
        const sep = std.mem.indexOf(uts.release[2..], ".") catch return false;
        const major = std.fmt.parseInt(usize, uts.release[0..1], 10) catch return false;
        const minor = std.fmt.parseInt(usize, uts.release[2 .. 2 + sep], 10) catch return false;
        return major >= 5 and minor >= 1;
    }

    pub fn init(self: *@This()) !void {}

    pub fn deinit(self: *@This()) void {}

    pub fn notify(self: *@This()) !void {}

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) !zio.Handle {}

    pub fn close(self: *@This(), handle: zio.Handle) void {}

    pub fn connect(self: *@This(), handle: zio.Handle, address: *const zio.Address) !void {}

    pub fn accept(self: *@This(), handle: zio.Handle, address: *zio.Address) !zio.Handle {}

    pub fn readv(self: *@This(), handle: zio.Handle, address: ?*zio.Address, buffer: []const []u8, offset: ?u64) !usize {}

    pub fn writev(self: *@This(), handle: zio.Handle, address: ?*const zio.Address, buffer: []const []const u8, offset: ?u64) !usize {}

    pub fn poll(self: *@This(), timeout_ms: ?u32) !Task.List {}

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
