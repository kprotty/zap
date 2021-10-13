const std = @import("std");
const os = std.os;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;
const Allocator = std.mem.Allocator;

const builtin = @import("builtin");
const target = builtin.target;
const single_threaded = builtin.single_threaded;

pub const Loop = @This();

lock: std.Thread.Mutex = .{},
runnable: Task.List = .{},
join_futex: Atomic(u32) = Atomic(u32).init(0),
idle: usize = 0,
spawned: usize = 0,
max_threads: usize,
running: bool = true,
notified: Atomic(bool) = Atomic(bool).init(false),
reactor: Reactor,

pub var instance: ?*Loop = null;

pub fn run(comptime asyncFn: anytype, args: anytype) !@typeInfo(@TypeOf(asyncFn)).Fn.return_type.? {
    const Args = @TypeOf(args);
    const Result = @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
    const Entry = struct {
        fn call(task: *Task, fn_args: Args) Result {
            suspend { 
                task.* = Task.init(@frame());
            }
            defer Loop.instance.?.shutdown();
            return @call(.{}, asyncFn, fn_args);
        }
    };

    var task: Task = undefined;
    var frame = async Entry.call(&task, args);
    try runTask(&task);
    return nosuspend await frame;
}

fn runTask(task: *Task) !void {
    var self = Loop{
        .reactor = try Reactor.init(),
        .max_threads = if (single_threaded) 1 else blk: {
            break :blk std.math.max(1, std.Thread.getCpuCount() catch 1);
        },
    };

    defer {
        self.shutdown();
        self.join();
        self.reactor.deinit();
    }

    assert(instance == null);
    instance = &self;
    defer instance = null;

    self.schedule(task);
}

pub fn schedule(self: *Loop, task: *Task) void {
    const held = self.lock.acquire();
    self.runnable.push(Task.List.from(task));

    if (!self.running) {
        return held.release();
    }

    if (self.idle > 0) {
        held.release();
        if (self.notified.load(.Monotonic)) return;
        if (self.notified.swap(true, .Acquire)) return;
        return self.reactor.notify();
    }

    if (self.spawned == self.max_threads) {
        return held.release();
    }

    const use_caller_thread = self.spawned == 0;
    self.spawned += 1;
    held.release();

    if (use_caller_thread) {
        return self.runWorker();
    }

    if (single_threaded) {
        @panic("Tried to spawn a Thread when single_threaded");
    }

    const thread = std.Thread.spawn(.{}, Loop.runWorker, .{self}) catch return self.finish();
    thread.detach();
}

fn runWorker(self: *Loop) void {
    defer self.finish();

    while (true) {
        const task = self.poll() catch break;
        resume task.node.data;
    }
}

fn poll(self: *Loop) error{Shutdown}!*Task {
    var held = self.lock.acquire();
    while (true) {
        if (self.runnable.pop()) |task| {
            held.release();
            return task;
        }

        if (!self.running) {
            held.release();
            return error.Shutdown;
        }

        self.idle += 1;
        held.release();

        var notified = false;
        var list = self.reactor.poll(&notified);

        if (notified) {
            assert(self.notified.load(.Monotonic));
            self.notified.store(false, .Release);
        }

        held = self.lock.acquire();
        self.runnable.push(list);
        self.idle -= 1;

        if (!self.running) blk: {
            if (self.notified.load(.Monotonic)) break :blk;
            if (self.notified.swap(true, .Acquire)) break :blk;
            self.reactor.notify();
        }
    }
}

fn shutdown(self: *Loop) void {
    if (blk: {
        const held = self.lock.acquire();
        defer held.release();

        self.running = false;
        break :blk (self.idle > 0);
    }) {
        if (self.notified.swap(true, .Acquire)) return;
        return self.reactor.notify();
    }
}

fn finish(self: *Loop) void {
    if (blk: {
        const held = self.lock.acquire();
        defer held.release();
        
        self.spawned -= 1;
        break :blk (self.spawned == 0 and !self.running and self.idle > 0);
    }) {
        self.join_futex.store(1, .Release);
        std.Thread.Futex.wake(&self.join_futex, 1);
    }
}

fn join(self: *Loop) void {
    var joining = false;
    defer while (joining and self.join_futex.load(.Acquire) == 0)
        std.Thread.Futex.wait(&self.join_futex, 0, null) catch unreachable;

    const held = self.lock.acquire();
    defer held.release();

    if (self.spawned == 0) {
        return;
    }

    assert(self.idle == 0);
    self.idle = 1;
}

pub const Task = struct {
    node: Queue.Node,

    const Queue = std.TailQueue(anyframe);

    pub fn init(frame: anyframe) Task {
        return .{ .node = .{ .data = frame } };
    }

    const List = struct {
        queue: Queue = .{},

        fn from(task: *Task) List {
            var queue = Queue{};
            queue.append(&task.node);
            return .{ .queue = queue };
        }

        fn push(self: *List, list: List) void {
            var _list = list;
            self.queue.concatByMoving(&_list.queue);
        }

        fn pop(self: *List) ?*Task {
            const node = self.queue.popFirst() orelse return null;
            return @fieldParentPtr(Task, "node", node);
        }
    };
};

const IoType = enum {
    read,
    write,
};

pub fn waitForReadable(self: *Loop, fd: os.fd_t) void {
    return self.waitFor(fd, .read);
}

pub fn waitForWritable(self: *Loop, fd: os.fd_t) void {
    return self.waitFor(fd, .write);
}

fn waitFor(self: *Loop, fd: os.fd_t, io_type: IoType) void {
    var completion: Reactor.Completion = undefined;
    completion.task = Task.init(@frame());
    suspend {
        self.reactor.schedule(fd, io_type, &completion) catch resume @frame();
    }
}

const Reactor = switch (target.os.tag) {
    .windows => WindowsReactor,
    .linux => LinuxReactor,
    else => BSDReactor,
};

const LinuxReactor = struct {
    epoll_fd: os.fd_t,
    event_fd: os.fd_t,

    pub fn init() !Reactor {
        var self: Reactor = undefined;

        self.epoll_fd = try os.epoll_create1(os.EPOLL.CLOEXEC);
        errdefer os.close(self.epoll_fd);

        self.event_fd = try os.eventfd(0, os.EFD.CLOEXEC | os.EFD.NONBLOCK);
        errdefer os.close(self.event_fd);

        try self.register(
            os.EPOLL.CTL_ADD,
            self.event_fd,
            os.EPOLL.IN, // level-triggered, readable
            0 // zero epoll_event.data.ptr for event_fd
        );

        return self;
    }

    fn deinit(self: Reactor) void {
        os.close(self.event_fd);
        os.close(self.epoll_fd);
    }

    const Completion = struct {
        task: Task,
    };

    fn schedule(self: Reactor, fd: os.fd_t, io_type: IoType, completion: *Completion) !void {
        const ptr = @ptrToInt(&completion.task);
        const events = os.EPOLL.ONESHOT | switch (io_type) {
            .read => os.EPOLL.IN | os.EPOLL.RDHUP,
            .write => os.EPOLL.OUT,
        };

        return self.register(os.EPOLL.CTL_MOD, fd, events, ptr) catch |err| switch (err) {
            error.FileDescriptorNotRegistered => self.register(os.EPOLL_CTL_ADD, fd, events, ptr),
            else => err,
        };
    }

    fn register(self: Reactor, op: u32, fd: os.fd_t, events: u32, user_data: usize) !void {
        var event = os.epoll_event{
            .data = .{ .ptr = user_data },
            .events = events | os.EPOLL.ERR | os.EPOLL.HUP,
        };
        try os.epoll_ctl(self.epoll_fd, op, fd, &event);
    }

    fn notify(self: Reactor) void {
        var value: u64 = 0;
        const wrote = os.write(self.event_fd, std.mem.asBytes(&value)) catch unreachable;
        assert(wrote == @sizeOf(u64));
    }

    fn poll(self: Reactor, notified: *bool) Task.List {
        var events: [128]os.epoll_event = undefined;
        const found = os.epoll_wait(self.epoll_fd, &events, -1);

        var list = Task.List{};
        for (events[0..found]) |ev| {
            list.push(Task.List.from(@intToPtr(?*Task, ev.data.ptr) orelse {
                var value: u64 = 0;
                const read = os.read(self.event_fd, std.mem.asBytes(&value)) catch unreachable;
                assert(read == @sizeOf(u64));
                
                assert(!notified.*);
                notified.* = true;
                continue;
            }));
        }

        return list;
    }
};

const BSDReactor = struct {
    kqueue_fd: os.fd_t,

    const notify_info = switch (target.os.tag) {
        .openbsd => .{
            .filter = os.system.EVFILT_TIMER,
            .fflags = 0,
        },
        else => .{
            .filter = os.system.EVFILT_USER,
            .fflags = os.system.NOTE_TRIGGER,
        },
    };

    fn init() !Reactor {
        var self = Reactor{ .kqueue_fd = try os.kqueue() };
        errdefer os.close(self.kqueue_fd);

        try self.kevent(.{
            .ident = 0, // zero-ident for notify event,
            .filter = notify_info.filter,
            .flags = os.system.EV_ADD | os.system.EV_CLEAR | os.system.EV_DISABLE,
            .fflags = 0, // fflags unused for notify_info.filter
            .udata = 0, // zero-udata for notify event
        });

        return self;
    }

    fn deinit(self: Reactor) void {
        os.close(self.kqueue_fd);
    }

    const Completion = struct {
        task: Task,
    };

    fn schedule(self: Reactor, fd: os.fd_t, io_type: IoType, completion: *Completion) !void {
        try self.kevent(.{
            .ident = @intCast(usize, fd),
            .filter = switch (io_type) {
                .read => os.system.EVFILT_READ,
                .write => os.system.EVFILT_WRITE,
            },
            .flags = os.system.EV_ADD | os.system.EV_ENABLE | os.system.EV_ONESHOT,
            .fflags = 0, // fflags usused for read/write events
            .udata = @ptrToInt(&completion.task),
        });
    }

    fn notify(self: Reactor) void {
        self.kevent(.{
            .ident = 0, // zero-ident for notify event
            .filter = notify_info.filter,
            .flags = os.system.EV_ENABLE,
            .fflags = notify_info.fflags,
            .udata = 0, // zero-udata for notify event
        }) catch unreachable;
    }

    fn kevent(self: Reactor, info: anytype) !void {
        var events: [1]os.Kevent = undefined;
        events[0] = .{
            .ident = info.ident,
            .filter = info.filter,
            .flags = info.flags,
            .fflags = info.fflags,
            .data = 0,
            .udata = info.udata,
        };

        _ = try os.kevent(
            self.kqueue_fd,
            &events,
            &[0]os.Kevent{},
            null,
        );
    }

    fn poll(self: Reactor, notified: *bool) Task.List {
        var events: [64]os.Kevent = undefined;
        const found = try os.kevent(
            self.kqueue_fd,
            &[0]os.Kevent{},
            &events,
            null,
        ) catch unreachable;

        var list = Task.List{};
        for (events[0..found]) |ev| {
            list.push(Task.List.from(@intToPtr(?*Task, ev.udata) orelse {
                assert(!notified.*);
                notified.* = true;
                continue;
            }));
        }

        return list;
    }
};

const WindowsReactor = struct {
    afd: os.windows.HANDLE,
    iocp: os.windows.HANDLE,

    fn init() !Reactor {
        const ascii_name = "\\Device\\Afd\\Zig";
        comptime var afd_name = std.mem.zeroes([ascii_name.len + 1]os.windows.WCHAR);
        inline for (ascii_name) |char, i| {
            afd_name[i] = @as(os.windows.WCHAR, char);
        }

        const afd_len = @intCast(os.windows.USHORT, afd_name.len) * @sizeOf(os.windows.WCHAR);
        var afd_string = os.windows.UNICODE_STRING{
            .Length = afd_len,
            .MaximumLength = afd_len,
            .Buffer = &afd_name,
        };

        var afd_attr = os.windows.OBJECT_ATTRIBUTES{
            .Length = @sizeOf(os.windows.OBJECT_ATTRIBUTES),
            .RootDirectory = null,
            .ObjectName = &afd_string,
            .Attributes = 0,
            .SecurityDescriptor = null,
            .SecurityQualityOfService = null,
        };

        var afd_handle: os.windows.HANDLE = undefined;
        var io_status_block: os.windows.IO_STATUS_BLOCK = undefined;
        switch (os.windows.ntdll.NtCreateFile(
            &afd_handle,
            os.windows.SYNCHRONIZE,
            &afd_attr,
            &io_status_block,
            null,
            0,
            os.windows.FILE_SHARE_READ | os.windows.FILE_SHARE_WRITE,
            os.windows.FILE_OPEN,
            0,
            null,
            0,
        )) {
            .SUCCESS => {},
            .OBJECT_NAME_INVALID => unreachable,
            else => |status| return os.windows.unexpectedStatus(status),
        }
        errdefer os.windows.CloseHandle(afd_handle);
        
        const iocp_handle = try os.windows.CreateIoCompletionPort(os.windows.INVALID_HANDLE_VALUE, null, 0, 0);
        errdefer os.windows.CloseHandle(iocp_handle);

        const iocp_afd_handle = try os.windows.CreateIoCompletionPort(afd_handle, iocp_handle, 1, 0);
        assert(iocp_afd_handle == iocp_handle);

        try os.windows.SetFileCompletionNotificationModes(
            afd_handle,
            os.windows.FILE_SKIP_SET_EVENT_ON_HANDLE,
        );

        return Reactor{
            .afd = afd_handle,
            .iocp = iocp_handle,
        };
    }

    fn deinit(self: Reactor) void {
        os.windows.CloseHandle(self.afd);
        os.windows.CloseHandle(self.iocp);
    }

    const AFD_POLL_HANDLE_INFO = extern struct {
        Handle: os.windows.HANDLE,
        Events: os.windows.ULONG,
        Status: os.windows.NTSTATUS,
    };

    const AFD_POLL_INFO = extern struct {
        Timeout: os.windows.LARGE_INTEGER,
        NumberOfHandles: os.windows.ULONG,
        Exclusive: os.windows.ULONG,
        Handles: [1]AFD_POLL_HANDLE_INFO,
    };

    const IOCTL_AFD_POLL = 0x00012024;
    const AFD_POLL_RECEIVE = 0x0001;
    const AFD_POLL_SEND = 0x0004;
    const AFD_POLL_DISCONNECT = 0x0008;
    const AFD_POLL_ABORT = 0b0010;
    const AFD_POLL_LOCAL_CLOSE = 0x020;
    const AFD_POLL_ACCEPT = 0x0080;
    const AFD_POLL_CONNECT_FAIL = 0x0100;

    const Completion = struct {
        task: Task,
        afd_poll_info: AFD_POLL_INFO,
        io_status_block: os.windows.IO_STATUS_BLOCK,
    };

    fn schedule(self: Reactor, fd: os.fd_t, io_type: IoType, completion: *Completion) !void {
        const afd_events = @as(os.windows.ULONG, switch (io_type) {
            .read => AFD_POLL_RECEIVE | AFD_POLL_ACCEPT | AFD_POLL_DISCONNECT,
            .write => AFD_POLL_SEND,
        });

        completion.afd_poll_info = .{
            .Timeout = std.math.maxInt(os.windows.LARGE_INTEGER),
            .NumberOfHandles = 1,
            .Exclusive = os.windows.FALSE,
            .Handles = [_]AFD_POLL_HANDLE_INFO{.{
                .Handle = fd,
                .Status = .SUCCESS,
                .Events = AFD_POLL_ABORT | AFD_POLL_LOCAL_CLOSE | AFD_POLL_CONNECT_FAIL | afd_events,
            }},
        };

        completion.io_status_block = .{
            .u = .{ .Status = .PENDING },
            .Information = 0,
        };

        const status = os.windows.ntdll.NtDeviceIoControlFile(
            self.afd,
            null,
            null,
            &completion.io_status_block,
            &completion.io_status_block,
            IOCTL_AFD_POLL,
            &completion.afd_poll_info,
            @sizeOf(AFD_POLL_INFO),
            &completion.afd_poll_info,
            @sizeOf(AFD_POLL_INFO),
        );

        switch (status) {
            .SUCCESS => {},
            .PENDING => {},
            .INVALID_HANDLE => unreachable,
            else => return os.windows.unexpectedStatus(status),
        }
    }

    fn notify(self: Reactor) void {
        var stub_overlapped: os.windows.OVERLAPPED = undefined;
        os.windows.PostQueuedCompletionStatus(
            self.iocp,
            undefined,
            0, // zero lpCompletionKey indicates notification for us
            &stub_overlapped,
        ) catch unreachable;
    }

    fn poll(self: Reactor, notified: *bool) Task.List {
        var entries: [128]os.windows.OVERLAPPED_ENTRY = undefined;
        const found = os.windows.GetQueuedCompletionStatusEx(
            self.iocp, 
            &entries,
            os.windows.INFINITE,
            false, // not alertable wait
        ) catch |err| switch (err) {
            error.Aborted => unreachable,
            error.Cancelled => unreachable,
            error.EOF => unreachable,
            error.Timeout => unreachable,
            else => unreachable,
        };

        var list = Task.List{};
        for (entries[0..found]) |entry| {
            if (entry.lpCompletionKey == 0) {
                assert(!notified.*);
                notified.* = true;
                continue;
            }

            const overlapped = entry.lpOverlapped;
            const io_status_block = @ptrCast(*os.windows.IO_STATUS_BLOCK, overlapped);
            const completion = @fieldParentPtr(Completion, "io_status_block", io_status_block);

            assert(io_status_block.u.Status != .CANCELLED);
            list.push(Task.List.from(&completion.task));
        }

        return list;
    }
};

pub const net = struct {
    pub const Address = std.net.Address;

    pub fn tcpConnectToHost(allocator: *Allocator, name: []const u8, port: u16) !Stream {
        const list = try std.net.getAddressList(allocator, name, port);
        defer list.deinit();

        if (list.addrs.len == 0) {
            return error.UnknownHostName;
        }

        for (list.addrs) |addr| {
            return tcpConnectToAddress(addr) catch |err| switch (err) {
                error.ConnectionRefused => continue,
                else => return err,
            };
        }
        return os.ConnectError.ConnectionRefused;
    }

    pub fn tcpConnectToAddress(address: Address) !Stream {
        const socket = try Socket.init(address.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);
        errdefer socket.close();

        try socket.connect(address);

        return Stream{ .socket = socket };
    }

    pub const Stream = struct {
        socket: Socket,

        pub fn deinit(self: *Stream) void {
            self.socket.deinit();
        }

        pub fn close(self: Stream) void {
            self.socket.close();
        }

        pub const ReadError = os.ReadError;
        pub const WriteError = os.WriteError;

        pub const Reader = std.io.Reader(Stream, ReadError, read);
        pub const Writer = std.io.Writer(Stream, WriteError, write);

        pub fn reader(self: Stream) Reader {
            return .{ .context = self };
        }

        pub fn writer(self: Stream) Writer {
            return .{ .context = self };
        }

        pub fn read(self: Stream, buffer: []u8) ReadError!usize {
            return self.socket.recvfrom(buffer, null);
        }

        pub fn write(self: Stream, buffer: []const u8) WriteError!usize {
            return self.socket.sendto(buffer, null);
        }
    };

    pub const StreamServer = struct {
        socket: ?Socket,
        options: Options,
        address: Address,

        pub const Options = struct {
            kernel_backlog: u31 = 128,
            reuse_address: bool = false,
        };

        pub fn init(options: Options) StreamServer {
            return .{
                .socket = null,
                .options = options,
                .address = undefined,
            };
        }

        pub fn deinit(self: *StreamServer) void {
            self.close();
            self.* = undefined;
        }

        pub fn close(self: *StreamServer) void {
            if (self.socket) |socket| {
                socket.close();
                self.socket = null;
                self.address = undefined;
            }
        }

        pub fn listen(self: *StreamServer, address: Address) !void {
            const proto = if (address.any.family == os.AF.UNIX) @as(u32, 0) else os.IPPROTO.TCP;
            const socket = try Socket.init(address.any.family, os.SOCK.STREAM, proto);
            errdefer socket.close();

            const sock_fd = socket.getHandle();
            self.socket = socket;
            errdefer self.socket = null;

            if (self.options.reuse_address) {
                try os.setsockopt(
                    sock_fd,
                    os.SOL.SOCKET,
                    os.SO.REUSEADDR,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            }

            self.address = address;
            var socklen = address.getOsSockLen();
            try os.bind(sock_fd, &self.address.any, socklen);
            try os.listen(sock_fd, self.options.kernel_backlog);
            try os.getsockname(sock_fd, &self.address.any, &socklen);            
        }

        pub const AcceptError = error{
            ConnectionAborted,
            /// The per-process limit on the number of open file descriptors has been reached.
            ProcessFdQuotaExceeded,
            /// The system-wide limit on the total number of open files has been reached.
            SystemFdQuotaExceeded,
            /// Not enough free memory.  This often means that the memory allocation  is  limited
            /// by the socket buffer limits, not by the system memory.
            SystemResources,
            /// Socket is not listening for new connections.
            SocketNotListening,
            ProtocolFailure,
            /// Firewall rules forbid connection.
            BlockedByFirewall,
            FileDescriptorNotASocket,
            ConnectionResetByPeer,
            NetworkSubsystemFailed,
            OperationNotSupported,
        } || os.UnexpectedError;

        pub const Connection = struct {
            stream: Stream,
            address: Address,
        };

        pub fn accept(self: *StreamServer) AcceptError!Connection {
            var address: Address = undefined;
            const socket = self.socket.?.accept(&address) catch |err| switch (err) {
                error.WouldBlock => unreachable,
                else => |e| return e,
            };

            return Connection{
                .stream = Stream{ .socket = socket },
                .address = address,
            };
        }
    };

    pub const Socket = struct {
        fd: os.socket_t,

        pub fn init(domain: u32, sock_type: u32, protocol: u32) !Socket {
            const fd = try os.socket(domain, sock_type | os.SOCK.NONBLOCK | os.SOCK.CLOEXEC, protocol);
            errdefer os.closeSocket(fd);
            return Socket.fromFd(fd);
        }

        fn fromFd(fd: os.socket_t) !Socket {
            if (comptime target.os.tag.isDarwin()) {
                try os.setsockopt(
                    fd,
                    os.SOL.SOCKET,
                    os.SO.NOSIGPIPE,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            }
            return Socket{ .fd = fd };
        }

        pub fn deinit(self: *Socket) void {
            self.close();
            self.fd = switch (target.os.tag) {
                .windows => os.windows.INVALID_HANDLE_VALUE,
                else => -1,
            };
        }

        pub fn getHandle(self: Socket) os.socket_t {
            return self.fd;
        }

        pub fn close(self: Socket) void {
            os.closeSocket(self.fd);
        }

        pub fn connect(self: Socket, addr: Address) !void {
            const OsConnect = struct {
                fn call(sock: os.socket_t, sock_addr: *os.sockaddr, len: os.socklen_t) !void {
                    if (target.os.tag != .windows) {
                        return os.connect(sock, sock_addr, len);
                    }

                    // stdlib does unreachable for WSAEWOULDBLOCK here for some reason
                    const rc = os.ws2_32.connect(sock, sock_addr, @intCast(i32, len));
                    if (rc == 0) return;
                    switch (os.windows.ws2_32.WSAGetLastError()) {
                        .WSAEADDRINUSE => return error.AddressInUse,
                        .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                        .WSAECONNREFUSED => return error.ConnectionRefused,
                        .WSAECONNRESET => return error.ConnectionResetByPeer,
                        .WSAETIMEDOUT => return error.ConnectionTimedOut,
                        .WSAEHOSTUNREACH,
                        .WSAENETUNREACH,
                        => return error.NetworkUnreachable,
                        .WSAEFAULT => unreachable,
                        .WSAEINVAL => unreachable,
                        .WSAEISCONN => unreachable,
                        .WSAENOTSOCK => unreachable,
                        .WSAEWOULDBLOCK => error.WouldBlock,
                        .WSAEACCES => unreachable,
                        .WSAENOBUFS => return error.SystemResources,
                        .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                        else => |err| return os.windows.unexpectedWSAError(err),
                    }
                }
            };

            OsConnect.call(self.fd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
                else => return err,
                error.WouldBlock => {
                    Loop.instance.?.waitForWritable(self.fd);
                    return os.getsockoptError(self.fd);
                },
            };
        }

        pub fn accept(self: Socket, addr: *Address) !Socket {
            var addr_len: os.socklen_t = @sizeOf(Address);
            while (true) {
                const fd = os.accept(self.fd, &addr.any, &addr_len, os.SOCK.CLOEXEC) catch |err| switch (err) {
                    else => return err,
                    error.WouldBlock => {
                        Loop.instance.?.waitForReadable(self.fd);
                        continue;
                    },
                };
                return Socket.fromFd(fd);
            }
        }

        const io_flags = switch (target.os.tag) {
            .macos, .ios, .watchos, .tvos => 0,
            .windows => 0,
            else => os.MSG_NOSIGNAL,
        };

        pub fn sendto(self: Socket, buf: []const u8, addr: ?Address) !usize {
            while (true) {
                const adr = if (addr) |*a| &a.any else null;
                const adr_len: os.socklen_t = if (addr) |_| @sizeOf(Address) else 0;

                return os.sendto(self.fd, buf, io_flags, adr, adr_len) catch |err| switch (err) {
                    else => return err,
                    error.WouldBlock => {
                        Loop.instance.?.waitForWritable(self.fd);
                        continue;
                    },
                };
            }
        }

        pub fn recvfrom(self: Socket, buf: []u8, addr: ?*Address) !usize {
            while (true) {
                var len: os.socklen_t = @sizeOf(Address);
                const adr = if (addr) |*a| &a.any else null;
                const adr_len = if (addr) |_| &len else null;

                return os.recvfrom(self.fd, buf, io_flags, adr, adr_len) catch |err| switch (err) {
                    else => return err,
                    error.WouldBlock => {
                        Loop.instance.?.waitForReadable(self.fd);
                        continue;
                    },
                };
            }
        }
    };
};