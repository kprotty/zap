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
        self.inner = try zio.Event.Poller.new();
        self.cache.init(allocator);
    }

    pub fn deinit(self: *@This()) void {
        self.cache.deinit();
        self.inner.close();
    }

    pub fn socket(self: *@This(), flags: zio.Socket.Flags) Reactor.SocketError!Reactor.TypedHandle {
        const sock = try zio.Socket.new(flags | zio.Socket.Nonblock);
        const descriptor = try self.register(sock.getHandle());
        return Reactor.TypedHandle{ .Socket = @ptrToInt(descriptor) };
    }

    pub fn close(self: *@This(), typed_handle: Reactor.TypedHandle) void {
        const descriptor = @intToPtr(*Descriptor, typed_handle.getValue());
        switch (typed_handle) {
            .Socket => zio.Socket.fromHandle(descriptor.handle, zio.Socket.Nonblock).close(),
        }
        self.cache.free(descriptor);
    }

    pub fn getHandle(self: *@This(), typed_handle: Reactor.TypedHandle) zio.Handle {
        const descriptor = @intToPtr(*Descriptor, typed_handle.getValue());
        return descriptor.handle;
    }

    pub fn accept(self: *@This(), typed_handle: Reactor.TypedHandle, flags: zio.Socket.Flags, address: *zio.Address) Reactor.AcceptError!Reactor.TypedHandle {
        const Self = @This();
        var incoming_client = zio.Address.Incoming.new(address.*);
        return self.performAsync(struct {
            fn run(this: *Self, sock: *zio.Socket, token: usize, sflags: zio.Socket.Flags, addr: *zio.Address, incoming: *zio.Address.Incoming) !Reactor.TypedHandle {
                _ = sock.accept(sflags | zio.Socket.Nonblock, incoming, token) catch |err| return err;
                addr.* = incoming.address;
                const client_sock = incoming.getSocket(sflags | zio.Socket.Nonblock);
                const descriptor = try this.register(client_sock.getHandle());
                return Reactor.TypedHandle{ .Socket = @ptrToInt(descriptor) };
            }
        }, false, typed_handle, accept, flags, address, &incoming_client);
    }

    pub fn connect(self: *@This(), typed_handle: Reactor.TypedHandle, address: *const zio.Address) Reactor.ConnectError!void {
        const Self = @This();
        return self.performAsync(struct {
            fn run(this: *Self, sock: *zio.Socket, token: usize, addr: *const zio.Address) !void {
                return sock.connect(addr, token);
            }
        }, true, typed_handle, connect, address);
    }

    pub fn read(self: *@This(), typed_handle: Reactor.TypedHandle, address: ?*zio.Address, buffers: []const []u8, offset: ?u64) Reactor.ReadError!usize {
        // TODO: add file support using `offset`
        const Self = @This();
        return self.performAsync(struct {
            fn run(this: *Self, sock: *zio.Socket, token: usize, addr: ?*zio.Address, buf: []const []u8, offs: ?u64) !usize {
                return sock.recvmsg(add, buf, token);
            }
        }, false, typed_handle, read, address, buffers, offset);
    }

    pub fn write(self: *@This(), typed_handle: Reactor.TypedHandle, address: ?*const zio.Address, buffers: []const []const u8, offset: ?u64) Reactor.WriteError!usize {
        // TODO: add file support using `offset`
        const Self = @This();
        return self.performAsync(struct {
            fn run(this: *Self, sock: *zio.Socket, token: usize, addr: ?*const zio.Address, buf: []const []const u8, offs: ?u64) !usize {
                return sock.sendmsg(addr, buf, token);
            }
        }, true, typed_handle, write, address, buffers, offset);
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
                for ([_]*zync.Atomic(?*Descriptor.Request){
                    &descriptor.writer,
                    &descriptor.reader,
                }) |request_ref| {
                    const request = request_ref.load(.Relaxed) orelse continue;
                    if (token & request.token_mask != request.token_mask)
                        continue;
                    if (request.token.swap(token, .Acquire) == 1)
                        task_list.push(&request.task);
                }
            }
        }
        return task_list;
    }

    /// Allocate a Descriptor struct for a handle.
    /// Use zio.Event.EdgeTrigger to save on calling `.reregister()`
    /// and to support wait-free based notification as seen in in `poll`.
    fn register(self: *@This(), handle: zio.Handle) !*Descriptor {
        const descriptor = try self.cache.alloc(handle);
        const event_flags = zio.Event.Readable | zio.Event.Writeable | zio.Event.EdgeTrigger;
        try self.inner.register(descriptor.handle, event_flags, @ptrToInt(descriptor));
        return descriptor;
    }

    /// Execute an IO operation, automatically suspending and resuming as needed.
    fn performAsync(self: *@This(), comptime IO: type, comptime is_writer: bool, typed_handle: Reactor.TypedHandle, comptime func_context: var, args: ...) @typeOf(func_context).ReturnType {
        const HandleType = @typeInfo(@typeInfo(@typeOf(IO.run)).Fn.args[1].arg_type.?).Pointer.child;
        const descriptor = @intToPtr(*Descriptor, typed_handle.getValue());
        var instance = HandleType.fromHandle(descriptor.handle, zio.Nonblock);
        var request = Descriptor.Request{
            .task = Task{},
            .token = zync.Atomic(usize).new(0),
            .token_mask = instance.getTokenMask(if (is_writer) zio.Event.Writeable else zio.Event.Readable),
        };

        const request_ptr = if (is_writer) &descriptor.writer else &descriptor.reader;
        request_ptr.store(&request, .Release);
        defer request_ptr.store(null, .Relaxed);

        return IO.run(self, &instance, 0, args) catch |e| switch (e) {
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
                    else => |raw_err| return raw_err,
                };
            },
            else => |raw_err| return raw_err,
        };
    }

    const Descriptor = struct {
        writer: zync.Atomic(?*Request),
        reader: zync.Atomic(?*Request),
        handle: zio.Handle align(@alignOf(usize)),

        pub fn next(self: *@This()) *?*@This() {
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
                    const prev_chunk = chunk.prev().*;
                    self.allocator.destroy(chunk);
                    self.top_chunk = prev_chunk;
                }
            }

            pub fn alloc(self: *@This(), handle: zio.Handle) !*Descriptor {
                const descriptor = try self.allocDescriptor();
                descriptor.reader.set(null);
                descriptor.writer.set(null);
                descriptor.handle = handle;
                return descriptor;
            }

            fn allocDescriptor(self: *@This()) !*Descriptor {
                self.mutex.acquire();
                defer self.mutex.release();

                // check the free list first (fast path)
                if (self.free_list) |free_descriptor| {
                    const descriptor = free_descriptor;
                    self.free_list = descriptor.next().*;
                    return descriptor;
                }

                // out of descriptors, allocate a new chunk and build a list from the descriptors
                const chunk = self.allocator.create(Chunk) catch |_| return error.OutOfResources;
                for (chunk.descriptors) |*descriptor, index| {
                    descriptor.next().* = null;
                    if (index != chunk.descriptors.len - 1)
                        descriptor.next().* = @ptrCast(*Descriptor, &chunk.descriptors[index + 1]);
                }
                const descriptor = &chunk.descriptors[1];
                self.free_list = &chunk.descriptors[2];

                // push the chunk to track for deinit() & return the newly allocated descriptor
                chunk.prev().* = self.top_chunk;
                self.top_chunk = chunk;
                return descriptor;
            }

            pub fn free(self: *@This(), descriptor: *Descriptor) void {
                self.mutex.acquire();
                defer self.mutex.release();
                descriptor.next().* = self.free_list;
                self.free_list = descriptor;
            }

            const Chunk = struct {
                pub const BlockSize = zuma.page_size;
                descriptors: [BlockSize / @sizeOf(Descriptor)]Descriptor align(BlockSize),

                /// Using the first descriptor to store meta-data (3 usize's reserved)
                /// Returns the previous chunk allocated by the cache for use in chaining.
                pub fn prev(self: *@This()) *?*@This() {
                    return @ptrCast(*?*@This(), &self.descriptors[0].reader);
                }
            };
        };
    };
};
