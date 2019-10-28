const std = @import("std");
const builtin = @import("builtin");
const zio = @import("../../../zap.zig").zio;
const zync = @import("../../../zap.zig").zync;
const zuma = @import("../../../zap.zig").zuma;
const Task = @import("../runtime.zig").Task;
const Reactor = @import("../reactor.zig").Reactor;

pub const DefaultReactor = struct {
    inner: zio.Event.Poller,
    cache: Descriptor.Cache,

    pub fn init(self: *@This(), allocator: *std.mem.Allocator) Reactor.Error!void {
        try self.inner.init();
        self.cache.init(allocator);
    }

    pub fn deinit(self: *@This()) void {
        self.cache.deinit();
        self.inner.close();
    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) Reactor.SocketError!Reactor.Handle {
        const sock = try zio.Socket.new(flags | zio.Socket.Nonblock);
        const handle = try self.register(sock.getHandle());
        return Reactor.Handle{ .Socket = handle };
    }

    pub fn close(self: *@This(), handle: Reactor.Handle) void {
        const descriptor = @intToPtr(*Descriptor, handle.getValue());
        switch (handle) {
            .Socket => zio.Socket.fromHandle(descriptor.handle, zio.Socket.Nonblock).close(),
        }
        self.cache.free(descriptor);
    }

    pub fn accept(self: *@This(), handle: Reactor.Handle, address: *zio.Address) Reactor.AcceptError!Reactor.Handle {
        var incoming_client = zio.Address.Incoming.new(address.*);
        return self.performAsync(struct {
            fn run(this: var, sock: *zio.Socket, token: usize, address: *zio.Address, incoming: *zio.Address.Incoming) !Reactor.Handle {
                _ = sock.accept(flags, &incoming, token) catch |err| return err;
                address.* = incoming.address;
                const sock = incoming.getSocket(zio.Socket.Nonblock);
                const handle = try this.register(sock.getHandle());
                return Reactor.Handle{ .Socket = handle };
            }
        }, false, handle, address, &incoming_client);
    }

    pub fn connect(self: *@This(), handle: Reactor.Handle, address: *const zio.Address) Reactor.ConnectError!void {
        return self.performAsync(struct {
            fn run(this: var, sock: *zio.Socket, token: usize, address: *const zio.Address) !void {
                return sock.connect(address, token);
            }
        }, true, handle, address);
    }

    pub fn read(self: *@This(), handle: Reactor.Handle, address: ?*zio.Address, buffers: []const []u8, offset: ?u64) Reactor.ReadError!usize {
        // TODO: add file support using `offset`
        return self.performAsync(struct {
            fn run(this: var, sock: *zio.Socket, token: usize, address: ?*zio.Address, buffers: []const []u8) !void {
                return sock.recvmsg(address, buffers, token);
            }
        }, true, handle, address);
    }

    pub fn write(self: *@This(), handle: Reactor.Handle, address: ?*const zio.Address, buffers: []const []const u8, offset: ?u64) Reactor.WriteError!usize {
        // TODO: add file support using `offset`
        return self.performAsync(struct {
            fn run(this: var, sock: *zio.Socket, token: usize, address: ?*const zio.Address, buffers: []const []const u8) !void {
                return sock.sendmsg(address, buffers, token);
            }
        }, true, handle, address);
    }

    pub fn notify(self: *@This()) Reactor.NotifyError!void {
        return self.inner.notify(0);
    }

    pub fn poll(self: *@This(), timeout_ms: ?u32) Reactor.PollError!Task.List {
        // Iterate ready'd descriptors and create a list of task represents those which should be executed.
        var task_list = Task.List{};
        var events: [64]zio.Event = undefined;
        const events_found = try self.inner.poll(events[0..], timeout_ms);
        for (events_found) |event| {

            // Check both the reader and writer for a matching request.
            // When found, use atomic_exchange() to notify the request of the token.
            // If the old request token is 1, then the request is suspended and its task should be resumed.
            if (@intToPtr(?*Descriptor, event.readData(&self.inner))) |descriptor| {
                const token = event.getToken();
                inline for ([_]?*Descriptor.Request{ descriptor.writer, descriptor.reader }) |request_ref| {
                    const request = request_ref orelse continue;
                    if (token & request.token_mask != request.token_mask)
                        continue;
                    if (request.token.swap(token, .Acquire) == 1)
                        list.push(&request.task);
                }
            }
        }
        return task_list;
    }

    /// Allocate a Descriptor struct for a handle.
    /// Use zio.Event.EdgeTrigger to save on calling `.reregister()`
    /// and to support wait-free based notification as seen in in `poll`.
    fn register(self: *@This(), handle: zio.Handle) !usize {
        const descriptor = self.cache.alloc(handle) orelse return error.OutOfResources;
        const event_flags = zio.Event.Readable | zio.Event.Writeable | zio.Event.EdgeTrigger;
        try self.inner.register(descriptor.handle, event_flags, @ptrToInt(descriptor));
        return @ptrToInt(descriptor);
    }

    /// Execute an IO operation, automatically suspending and resuming as needed.
    fn performAsync(self: *@This(), comptime is_writer: bool, comptime IO: type, handle: Reactor.Handle, args: ...) @typeOf(IO.run).ReturnType {
        const HandleType = @typeInfo(@typeInfo(IO.run).Fn.args[1].arg_type.?).Pointer.child;
        const descriptor = @intToPtr(*Descriptor, handle.getValue());
        var instance = HandleType.fromHandle(descriptor.handle, zio.Nonblock);
        var request = Descriptor.Request{
            .task = Task{},
            .token = zync.Atomic(usize).new(0),
            .token_mask = instance.getTokenMask(if (is_writer) zio.Event.Writeable else zio.Event.Readable),
        };

        const request_ptr = if (is_writer) &descriptor.writer else &descriptor.reader;
        request_ptr.* = &request;
        defer request_ptr.* = null;

        return IO.run(self, &instance, 0, args) catch |err| switch (err) {
            zio.Error.Closed => return error.Closed,
            zio.Error.InvalidToken => unreachable,
            zio.Error.Pending => {
                suspend {
                    request.task.frame = @frame();
                    if (request.token.swap(1, .Release) != 0)
                        resume request.task.frame;
                }
                return IO.run(self, &instance, request.token.load(.Relaxed), args) catch |err| switch (err) {
                    zio.Error.Closed => return error.Closed,
                    zio.Error.InvalidToken => unreachable,
                    zio.Error.Pending => unreachable,
                    else => |err| return err,
                };
            },
            else => |err| return err,
        };
    }

    const Descriptor = struct {
        reserved: usize,
        writer: ?*Request,
        reader: ?*Request,
        handle: zio.Handle align(@alignOf(usize)),

        pub fn next(self: *const @This()) *?*@This() {
            return @ptrCast(*?*@This(), &self.reader);
        }

        pub const Request = struct {
            task: Task,
            token_mask: usize,
            token: zync.Atomic(usize),
        };

        pub const EventMask = usize;
        pub const Closed: EventMask = 1 << 0;
        pub const ReaderWaiting: EventMask = 1 << 1;
        pub const ReaderNotified: EventMask = 1 << 2;
        pub const WriterWaiting: EventMask = 1 << 3;
        pub const WriterNotified: EventMask = 1 << 4;

        pub const Cache = struct {
            mutex: zync.Mutex,
            top_chunk: ?*Chunk,
            free_list: ?*Descriptor,
            allocator: *std.mem.Allocator,

            pub fn init(self: *@This(), allocator: *std.mem.Allocator) void {
                self.mutex.init();
                self.free_list = null;
                self.top_chunk = null;
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

            pub fn alloc(self: *@This(), handle: zio.Handle) ?*Descriptor {
                const descriptor = self.allocDescriptor() orelse return null;
                descriptor.handle = handle;
                descriptor.reader = null;
                descriptor.writer = null;
                return descriptor;
            }

            fn allocDescriptor(self: *@This()) ?*Descriptor {
                self.mutex.acquire();
                defer self.mutex.release();

                if (self.free_list) |descriptor| {
                    self.free_list = descriptor.next().*;
                    return descriptor;
                }

                const chunk = self.allocator.create(Chunk) catch return null;
                chunk.prev().* = self.top_chunk;
                self.top_chunk = chunk;

                const size = chunk.descriptors.len;
                for (chunk.descriptors[1..]) |*descriptor, index|
                    descriptor.next().* = if (index == size - 1) null else &chunk.descriptors[index + 2 ..];
                self.free_list = &chunk.descriptors[2];
                return &chunk.descriptors[1];
            }

            pub fn free(self: *@This(), descriptor: *Descriptor) void {
                self.mutex.acquire();
                defer self.mutex.release();
                descriptor.next().* = self.free_list;
                self.free_list = descriptor;
            }

            const Chunk = struct {
                pub const PageSize = std.math.max(64 * 1024, zuma.page_size);
                descriptors: [PageSize / @sizeOf(Descriptor)]Descriptor align(PageSize),

                /// Using the first descriptor to store meta-data (3 usize's reserved)
                /// Returns the previous chunk allocated by the cache for use in chaining.
                pub fn prev(self: *@This()) *?*@This() {
                    return @ptrCast(*?*@This(), &self.descriptors[0].reader);
                }
            };
        };
    };
};
