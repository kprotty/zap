const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const net = std.net;
const Task = @import("executor.zig").Task;

const backend = switch (builtin.os) {
    .windows => @import("reactor/windows.zig"),
    .linux => @import("reactor/linux.zig"),
    else => @import("reactor/bsd.zig"),
};

pub const Descriptor = struct {
    inner: backend.Descriptor,

    pub fn getHandle(self: Descriptor) os.fd_t {
        return self.inner.getHandle();
    }
};

pub const Reactor = struct {
    lock: u32,
    inner: backend.Reactor,

    pub const Error = error{

    };

    pub fn init() Error!Reactor {
        return Reactor{ .inner = backend.Reactor.init() };
    }

    pub fn deinit(self: *Reactor) void {
        return self.inner.deinit();
    }

    pub const RegisterError = error{

    };

    pub fn register(self: *Reactor, handle: os.fd_t) RegisterError!*Descriptor {
        return @ptrCast(*Descriptor, try self.inner.register(handle));
    }

    pub fn close(self: *Reactor, descriptor: *Descriptor) void {
        return self.inner.close(&descriptor.inner);
    }

    pub const AcceptError = error{

    };

    pub fn accept(self: *Reactor, descriptor: *Descriptor, address: *net.Address) AcceptError!*Descriptor {
        return @ptrCast(*Descriptor, try self.inner.accept(address, &descriptor.inner));
    }

    pub const ConnectError = error{

    };

    pub fn connect(self: *Reactor, descriptor: *Descriptor, address: *const net.Address) ConnectError!void {
        return self.inner.connect(&descriptor.inner, address);
    }

    pub const ReadError = error{

    };

    pub fn read(self: *Reactor, descriptor: *Descriptor, data: []const os.iovec, address: ?*net.Address) ReadError!usize {
        return self.inner.read(&descriptor.inner, data, address);
    }

    pub const WriteError = error{

    };

    pub fn write(self: *Reactor, descriptor: *Descriptor, data: []const os.iovec_const, address: ?*const net.Address) WriteError!usize {
        return self.inner.write(&descriptor.inner, data, address);
    }

    pub const FsyncError = error{

    };

    pub fn fsync(self: *Reactor, descriptor: *Descriptor) FsyncError!void {
        return self.inner.fsync(&descriptor.inner);
    }

    pub const FileReadError = error{

    };

    pub fn fread(self: *Reactor, descriptor: *Descriptor, data: []const os.iovec, offset: ?u64) FileReadError!usize {
        return self.inner.fread(&descriptor.inner, data, offset);
    }

    pub const FileWriteError = error{

    };

    pub fn fwrite(self: *Reactor, descriptor: *Descriptor, data: []const os.iovec_const, offset: ?u64) FileWriteError!usize {
        return self.inner.fwrite(&descriptor.inner, data, offset);
    }

    pub const PollError = error{

    };

    pub fn poll(self: *Reactor, blocking: bool) PollError!Task.List {
        // acquire a lock in order to reduce event poller contention
        if (@atomicRmw(@typeOf(self.lock), &self.lock, .Xchg, 1, .Acquire) == 0) {
            defer @atomicStore(@typeOf(self.lock), &self.lock, 0, .Release);
            return self.inner.poll(blocking);
        }

        return Task.List{
            .head = null,
            .tail = null,
            .size = 0,
        };
    }
};