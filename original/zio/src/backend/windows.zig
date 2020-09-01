const std = @import("std");
const windows = std.os.windows;
const posix = @import("posix.zig");

const zio = @import("../../../zap.zig").zio;
const zync = @import("../../../zap.zig").zync;
const zuma = @import("../../../zap.zig").zuma;

pub const Handle = windows.HANDLE;

pub const Buffer = struct {
    inner: WSABUF,

    pub fn getBytes(self: @This()) []u8 {
        return self.inner.buf[0..self.inner.len];
    }

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This(){
            .inner = WSABUF{
                .buf = bytes.ptr,
                .len = @intCast(windows.DWORD, bytes.len),
            },
        };
    }
};

pub const IncomingPadding = 16;
pub const SockAddr = extern struct {
    pub const Ipv4 = SOCKADDR_IN;
    pub const Ipv6 = SOCKADDR_IN6;

    inner: SOCKADDR,

    pub fn fromIpv4(address: u32, port: u16) @This() {
        return @This(){
            .inner = SOCKADDR{
                .in = Ipv4{
                    .sin_family = AF_INET,
                    .sin_zero = [_]u8{0} ** 8,
                    .sin_addr = IN_ADDR{ .s_addr = address },
                    .sin_port = @intCast(c_ushort, std.mem.nativeToBig(u16, port)),
                },
            },
        };
    }

    pub fn fromIpv6(address: u128, port: u16, flowinfo: u32, scope: u32) @This() {
        return @This(){
            .inner = SOCKADDR{
                .in6 = Ipv6{
                    .sin6_family = AF_INET6,
                    .sin6_scope_id = scope,
                    .sin6_flowinfo = flowinfo,
                    .sin6_addr = IN6_ADDR{ .Byte = @bitCast([16]u8, address) },
                    .sin6_port = @intCast(c_ushort, std.mem.nativeToBig(u16, port)),
                },
            },
        };
    }
};

pub const Event = struct {
    inner: OVERLAPPED_ENTRY,

    pub fn getToken(self: @This()) usize {
        return @ptrToInt(self.inner.lpOverlapped);
    }

    pub fn readData(self: @This(), poller: *Poller) usize {
        return self.inner.lpCompletionKey;
    }

    pub const Poller = struct {
        iocp: Handle,

        pub fn new() zio.Event.Poller.Error!@This() {
            const handle = windows.kernel32.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, undefined, 0) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            return @This(){ .iocp = handle };
        }

        pub fn close(self: *@This()) void {
            _ = windows.CloseHandle(self.iocp);
        }

        pub fn fromHandle(handle: Handle) @This() {
            return @This(){ .iocp = handle };
        }

        pub fn getHandle(self: @This()) Handle {
            return self.iocp;
        }

        pub fn register(self: *@This(), handle: Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            if (handle == windows.INVALID_HANDLE_VALUE)
                return zio.Event.Poller.RegisterError.InvalidHandle;
            _ = windows.kernel32.CreateIoCompletionPort(handle, self.iocp, data, 0) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        pub fn reregister(self: *@This(), handle: Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            if (handle == windows.INVALID_HANDLE_VALUE)
                return zio.Event.Poller.RegisterError.InvalidHandle;
        }

        pub fn notify(self: *@This(), data: usize) zio.Event.Poller.NotifyError!void {
            if (self.iocp == windows.INVALID_HANDLE_VALUE)
                return zio.Event.Poller.NotifyError.InvalidValue;
            if (windows.kernel32.PostQueuedCompletionStatus(self.iocp, 0, data, null) != windows.TRUE)
                return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        pub fn poll(self: *@This(), events: []Event, timeout: ?u32) zio.Event.Poller.PollError![]Event {
            var events_found: windows.ULONG = 0;
            if (GetQueuedCompletionStatusEx(
                self.iocp,
                @ptrCast([*]OVERLAPPED_ENTRY, events.ptr),
                @intCast(windows.ULONG, events.len),
                &events_found,
                timeout orelse windows.INFINITE,
                windows.FALSE,
            ) == windows.TRUE)
                return events[0..events_found];

            const err_code = windows.kernel32.GetLastError();
            if (self.iocp == windows.INVALID_HANDLE_VALUE)
                return zio.Event.Poller.PollError.InvalidHandle;
            if (timeout == null or err_code == WAIT_TIMEOUT)
                return events[0..0];
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    };
};

pub const Socket = struct {
    handle: Handle,
    reader: windows.OVERLAPPED,
    writer: windows.OVERLAPPED,

    pub fn new(flags: zio.Socket.Flags) zio.Socket.Error!@This() {
        _ = try init_error.get();
        const handle = createSocket(flags);
        if (handle != INVALID_SOCKET)
            return fromHandle(handle, flags);
        return switch (Winsock2.get().?.WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN, WSAEINPROGRESS, WSAEINVALIDPROVIDER, WSAEINVALIDPROCTABLE, WSAEPROVIDERFAILEDINIT => zio.Socket.Error.InvalidState,
            WSAEAFNOTSUPPORT, WSAEFAULT, WSAEINVAL, WSAEPROTONOSUPPORT, WSAEPROTOTYPE, WSAESOCKTNOSUPPORT => zio.Socket.Error.InvalidValue,
            WSAEMFILE, WSAENOBUFS => zio.Socket.Error.OutOfResources,
            else => unreachable,
        };
    }

    pub fn close(self: *@This()) void {
        _ = Winsock2.get().?.closesocket(self.handle);
    }

    const is_overlapped = usize(1);

    pub fn fromHandle(handle: Handle, flags: zio.Socket.Flags) @This() {
        var self: @This() = undefined;
        self.handle = handle;
        if ((flags & zio.Socket.Nonblock) != 0)
            self.handle = @intToPtr(Handle, @ptrToInt(handle) | is_overlapped);
        return self;
    }

    pub fn getHandle(self: @This()) Handle {
        return @intToPtr(Handle, @ptrToInt(self.handle) & ~is_overlapped);
    }

    var init_error = zync.Lazy(WSAInitialize).new();
    fn WSAInitialize() zio.Socket.Error!void {
        const wsa_version = windows.WORD(0x0202);
        var wsa_data: WSAData = undefined;
        if (Winsock2.get().?.WSAStartup(wsa_version, &wsa_data) != 0)
            return zio.Socket.Error.InvalidState;
        if (wsa_data.wVersion != wsa_version)
            return zio.Socket.Error.InvalidState;

        const dummy_socket = createSocket(zio.Socket.Ipv4 | zio.Socket.Tcp);
        if (dummy_socket == INVALID_SOCKET)
            return zio.Socket.Error.InvalidState;
        defer {
            _ = Winsock2.get().?.closesocket(dummy_socket);
        }

        if (AcceptEx == null)
            try findWSAFunction(dummy_socket, WSAID_ACCEPTEX, &AcceptEx);
        if (ConnectEx == null)
            try findWSAFunction(dummy_socket, WSAID_CONNECTEX, &ConnectEx);
        if (GetAcceptExSockaddrs == null)
            try findWSAFunction(dummy_socket, WSAID_GETACCEPTEXSOCKADDRS, &GetAcceptExSockaddrs);
    }

    fn findWSAFunction(socket: SOCKET, function_guid: windows.GUID, function: var) zio.Socket.Error!void {
        var guid = function_guid;
        var dwBytes: windows.DWORD = undefined;
        const result = Winsock2.get().?.WSAIoctl(
            socket,
            SIO_GET_EXTENSION_FUNCTION_POINTER,
            @ptrCast(windows.PVOID, &guid),
            @sizeOf(@typeOf(guid)),
            @ptrCast(windows.PVOID, function),
            @sizeOf(@typeInfo(@typeOf(function)).Pointer.child),
            &dwBytes,
            null,
            null,
        );
        if (result != 0)
            return zio.Socket.Error.InvalidState;
    }

    pub fn getTokenMask(self: *const @This(), comptime event_flags: zio.Event.Flags) usize {
        return switch (event_flags & zio.Event.Readable) {
            0 => @ptrToInt(&self.writer),
            else => @ptrToInt(&self.reader),
        };
    }

    pub const Linger = extern struct {
        l_onoff: c_ushort,
        l_linger: c_ushort,
    };

    inline fn setUpdateContext(option: c_int, handle: Handle, value: usize, length: c_int) c_int {
        return Winsock2.get().?.setsockopt(handle, Options.SOL_SOCKET, option, value, length);
    }

    pub fn setOption(self: *@This(), option: zio.Socket.Option) zio.Socket.OptionError!void {
        var option_val = option;
        if (posix.Socket.socketOption(self.getHandle(), &option_val, Winsock2.get().?.setsockopt, Options) == 0)
            return;
        return switch (Winsock2.get().?.WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN, WSAEINPROGRESS => zio.Socket.OptionError.InvalidState,
            WSAENETRESET, WSAENOTCONN, WSAENOTSOCK => zio.Socket.OptionError.InvalidHandle,
            WSAEINVAL, WSAENOPROTOOPT => zio.Socket.OptionError.InvalidValue,
            WSAEFAULT => unreachable,
            else => unreachable,
        };
    }

    pub fn getOption(self: @This(), option: *zio.Socket.Option) zio.Socket.OptionError!void {
        if (posix.Socket.socketOption(self.getHandle(), option, Winsock2.get().?.getsockopt, Options) == 0)
            return;
        return switch (Winsock2.get().?.WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN, WSAEINPROGRESS => zio.Socket.OptionError.InvalidState,
            WSAEFAULT, WSAENOPROTOOPT => zio.Socket.OptionError.InvalidValue,
            WSAENOTSOCK => zio.Socket.OptionError.InvalidHandle,
            WSAEINVAL => unreachable,
            else => unreachable,
        };
    }

    pub fn bind(self: *@This(), address: *const zio.Address) zio.Socket.BindError!void {
        if (Winsock2.get().?.bind(self.getHandle(), @ptrCast(*const SOCKADDR, &address.sockaddr), address.length) == 0)
            return;
        return switch (Winsock2.get().?.WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN, WSAENOBUFS, WSAEINPROGRESS => zio.Socket.BindError.InvalidState,
            WSAEADDRNOTAVAIL, WSAEACCES, WSAEFAULT => zio.Socket.BindError.InvalidAddress,
            WSAENOTSOCK, WSAEINVAL => zio.Socket.BindError.InvalidHandle,
            WSAEADDRINUSE => zio.Socket.BindError.AddressInUse,
            else => unreachable,
        };
    }

    pub fn listen(self: *@This(), backlog: c_uint) zio.Socket.ListenError!void {
        if (Winsock2.get().?.listen(self.getHandle(), backlog) == 0)
            return;
        return switch (Winsock2.get().?.WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN, WSAENOBUFS, WSAEINPROGRESS, WSAEINVAL => zio.Socket.ListenError.InvalidState,
            WSAEISCONN, WSAEMFILE, WSAENOTSOCK, WSAEOPNOTSUPP => zio.Socket.ListenError.InvalidHandle,
            WSAEADDRINUSE => zio.Socket.ListenError.AddressInUse,
            else => unreachable,
        };
    }

    fn finishConnect(handle: Handle) zio.Socket.ConnectError!void {
        if (setUpdateContext(Options.SO_UPDATE_CONNECT_CONTEXT, handle, 0, 0) != 0)
            return zio.Socket.ConnectError.InvalidState;
    }

    pub fn connect(self: *@This(), address: *const zio.Address, token: usize) zio.Socket.ConnectError!void {
        return switch (error_code: {
            const handle = self.getHandle();
            switch (try self.getOverlappedResult(&self.writer, token)) {
                .Error => |code| break :error_code code,
                .Completed => |_| return finishConnect(handle),
                .Retry => |overlapped| {
                    const addr = @ptrCast(*const SOCKADDR, &address.sockaddr);
                    if (overlapped) |ov| {
                        var bind_address = switch (address.length) {
                            @sizeOf(SockAddr.Ipv4) => zio.Address.fromIpv4(0, 0),
                            @sizeOf(SockAddr.Ipv6) => zio.Address.fromIpv6(0, 0, 0, 0),
                            else => return zio.Socket.ConnectError.InvalidAddress,
                        };
                        self.bind(&bind_address) catch return zio.Socket.ConnectError.InvalidHandle;
                        if ((ConnectEx.?)(handle, addr, address.length, null, 0, null, ov) == windows.TRUE)
                            return finishConnect(handle);
                    } else {
                        if (Winsock2.get().?.WSAConnect(handle, addr, address.length, null, null, null, null) == 0)
                            return;
                    }
                    break :error_code Winsock2.get().?.WSAGetLastError();
                },
            }
        }) {
            0 => unreachable,
            WSAENOTINITIALIZED, WSAENETDOWN, WSAENETUNREACH, WSAENOBUFS => zio.Socket.ConnectError.InvalidState,
            WSAEAFNOTSUPPORT, WSAENOTSOCK => zio.Socket.ConnectError.InvalidHandle,
            WSAEWOULDBLOCK, WSA_IO_PENDING, WSA_IO_INCOMPLETE => zio.Error.Pending,
            WSAEADDRNOTAVAIL, WSAEINVAL => zio.Socket.ConnectError.InvalidAddress,
            WSAEADDRINUSE, WSAECONNREFUSED, WSAEHOSTUNREACH => zio.Error.Closed,
            WSAEALREADY, WSAEISCONN => zio.Socket.ConnectError.AlreadyConnected,
            WSAETIMEDOUT => zio.Socket.ConnectError.TimedOut,
            else => unreachable,
        };
    }

    fn finishAccept(handle_ptr: *Handle, incoming: *zio.Address.Incoming) zio.Socket.AcceptError!void {
        if (setUpdateContext(Options.SO_UPDATE_ACCEPT_CONTEXT, incoming.handle, @ptrToInt(handle_ptr), @sizeOf(Handle)) != 0)
            return zio.Socket.AcceptError.InvalidState;

        var local_addr: *SOCKADDR = undefined;
        var local_addr_len: windows.DWORD = 0;
        var remote_addr: *SOCKADDR = undefined;
        var remote_addr_len: windows.DWORD = 0;
        const addr_len = incoming.address.length;
        const addr = @ptrCast(windows.PVOID, &incoming.address.sockaddr);
        (GetAcceptExSockaddrs.?)(addr, 0, 0, addr_len, &local_addr, &local_addr_len, &remote_addr, &remote_addr_len);
        incoming.address.sockaddr.inner = remote_addr.*;
    }

    pub fn accept(self: *@This(), flags: zio.Socket.Flags, incoming: *zio.Address.Incoming, token: usize) zio.Socket.AcceptError!void {
        return switch (error_code: {
            var handle = self.getHandle();
            switch (try self.getOverlappedResult(&self.reader, token)) {
                .Error => |code| break :error_code code,
                .Completed => |_| return finishAccept(&handle, incoming),
                .Retry => |overlapped| {
                    if (overlapped) |ov| {
                        incoming.handle = createSocket(flags);
                        if (incoming.handle == INVALID_SOCKET)
                            return zio.Socket.AcceptError.OutOfResources;
                        var received: windows.DWORD = 0;
                        const addr_len = incoming.address.length;
                        const addr = @ptrCast(windows.PVOID, &incoming.address.sockaddr);
                        if ((AcceptEx.?)(handle, incoming.handle, addr, 0, 0, addr_len + IncomingPadding, &received, ov) == windows.TRUE)
                            return finishAccept(&handle, incoming);
                    } else {
                        const addr = @ptrCast(*SOCKADDR, &incoming.address.sockaddr);
                        incoming.handle = Winsock2.get().?.WSAAccept(handle, addr, &incoming.address.length, null, null);
                        if (incoming.handle != INVALID_SOCKET)
                            return;
                    }
                    break :error_code Winsock2.get().?.WSAGetLastError();
                },
            }
        }) {
            0 => unreachable,
            WSAECONNRESET => err: {
                if (token != 0)
                    _ = Winsock2.get().?.closesocket(incoming.handle);
                break :err zio.Error.Closed;
            },
            WSAENOTINITIALIZED, WSAEINTR, WSAEINPROGRESS, WSAENETDOWN => zio.Socket.AcceptError.InvalidState,
            WSAEINVAL, WSAENOTSOCK, WSAEOPNOTSUPP => zio.Socket.AcceptError.InvalidHandle,
            WSAEWOULDBLOCK, WSA_IO_PENDING, WSA_IO_INCOMPLETE => zio.Error.Pending,
            WSAEMFILE, WSAENOBUFS => zio.Socket.AcceptError.OutOfResources,
            WSAEFAULT => zio.Socket.AcceptError.InvalidAddress,
            else => unreachable,
        };
    }

    pub fn recvmsg(self: *@This(), address: ?*zio.Address, buffers: []Buffer, token: usize) zio.Socket.DataError!usize {
        return switch (error_code: {
            switch (try self.getOverlappedResult(&self.reader, token)) {
                .Completed => |transferred| return transferred,
                .Error => |code| break :error_code code,
                .Retry => |overlapped| {
                    var flags: windows.DWORD = 0;
                    var transferred: windows.DWORD = 0;
                    const result = Winsock2.get().?.WSARecvFrom(
                        self.getHandle(),
                        @ptrCast([*]WSABUF, buffers.ptr),
                        @intCast(windows.DWORD, buffers.len),
                        if (overlapped != null) null else &transferred,
                        &flags,
                        if (address) |addr| @ptrCast(*SOCKADDR, &addr.sockaddr) else null,
                        if (address) |addr| &addr.length else null,
                        overlapped,
                        null,
                    );
                    if (result == SOCKET_ERROR)
                        break :error_code Winsock2.get().?.WSAGetLastError();
                    return transferred;
                },
            }
        }) {
            0 => unreachable,
            WSAEDISCON, WSAECONNRESET, WSAENETRESET, WSA_OPERATION_ABORTED, WSAECONNABORTED, WSAETIMEDOUT => zio.Error.Closed,
            WSAEINPROGRESS, WSAEINTR, WSAENETDOWN, WSAENOTINITIALIZED => zio.Socket.DataError.InvalidState,
            WSAEINVAL, WSAENOTCONN, WSAENOTSOCK, WSAEOPNOTSUPP => zio.Socket.DataError.InvalidHandle,
            WSAEWOULDBLOCK, WSA_IO_PENDING, WSA_IO_INCOMPLETE => zio.Error.Pending,
            WSAEMSGSIZE => zio.Socket.DataError.BufferTooLarge,
            WSAENOBUFS => zio.Socket.DataError.OutOfResources,
            WSAEFAULT => zio.Socket.DataError.InvalidValue,
            else => unreachable,
        };
    }

    pub fn sendmsg(self: *@This(), address: ?*const zio.Address, buffers: []const Buffer, token: usize) zio.Socket.DataError!usize {
        return switch (error_code: {
            switch (try self.getOverlappedResult(&self.writer, token)) {
                .Completed => |transferred| return transferred,
                .Error => |code| break :error_code code,
                .Retry => |overlapped| {
                    var transferred: windows.DWORD = 0;
                    const result = Winsock2.get().?.WSASendTo(
                        self.getHandle(),
                        @ptrCast([*]const WSABUF, buffers.ptr),
                        @intCast(windows.DWORD, buffers.len),
                        &transferred,
                        windows.DWORD(0),
                        if (address) |addr| @ptrCast(*const SOCKADDR, &addr.sockaddr) else null,
                        if (address) |addr| addr.length else 0,
                        overlapped,
                        null,
                    );
                    if (result == SOCKET_ERROR)
                        break :error_code Winsock2.get().?.WSAGetLastError();
                    return transferred;
                },
            }
        }) {
            0 => unreachable,
            WSAEAFNOTSUPPORT, WSAEINVAL, WSAENETDOWN, WSAENOTCONN, WSAENOTSOCK, WSAESHUTDOWN, WSAEOPNOTSUPP => zio.Socket.DataError.InvalidHandle,
            WSAECONNRESET, WSAECONNABORTED, WSAETIMEDOUT, WSAENETRESET, WSAENETUNREACH, WSA_OPERATION_ABORTED => zio.Error.Closed,
            WSAEACCES, WSAEADDRNOTAVAIL, WSAEDESTADDRREQ, WSAEFAULT, WSAEHOSTUNREACH => zio.Socket.DataError.InvalidValue,
            WSAEINPROGRESS, WSAEINTR, WSAENOTINITIALIZED => zio.Socket.DataError.InvalidState,
            WSAEWOULDBLOCK, WSA_IO_PENDING, WSA_IO_INCOMPLETE => zio.Error.Pending,
            WSAEMSGSIZE => zio.Socket.DataError.BufferTooLarge,
            WSAENOBUFS => zio.Socket.DataError.OutOfResources,
            else => unreachable,
        };
    }

    const OverlappedResult = union(enum) {
        Error: c_int,
        Completed: usize,
        Retry: ?*windows.OVERLAPPED,
    };

    fn getOverlappedResult(self: *@This(), overlapped: *windows.OVERLAPPED, token: usize) zio.Error.Set!OverlappedResult {
        if (token == @ptrToInt(overlapped)) {
            var flags: windows.DWORD = 0;
            var transferred: windows.DWORD = 0;
            if (Winsock2.get().?.WSAGetOverlappedResult(self.getHandle(), overlapped, &transferred, windows.FALSE, &flags) == windows.TRUE)
                return OverlappedResult{ .Completed = transferred };
            return OverlappedResult{ .Error = Winsock2.get().?.WSAGetLastError() };
        } else if (token != 0) {
            return zio.Error.InvalidToken;
        }

        const use_overlapped = (@ptrToInt(self.handle) & is_overlapped) != 0;
        if (use_overlapped)
            @memset(@ptrCast([*]u8, overlapped), 0, @sizeOf(windows.OVERLAPPED));
        return OverlappedResult{ .Retry = if (use_overlapped) overlapped else null };
    }

    fn createSocket(flags: zio.Socket.Flags) Handle {
        var family: windows.DWORD = 0;
        var sock_type: windows.DWORD = 0;
        var protocol: windows.DWORD = 0;

        if ((flags & zio.Socket.Ipv4) != 0) {
            family |= AF_INET;
        } else if ((flags & zio.Socket.Ipv6) != 0) {
            family |= AF_INET6;
        }
        if ((flags & zio.Socket.Raw) != 0) {
            family |= AF_UNSPEC;
            sock_type |= SOCK_RAW;
        } else if ((flags & zio.Socket.Tcp) != 0) {
            sock_type |= SOCK_STREAM;
            protocol |= Options.IPPROTO_TCP;
        } else if ((flags & zio.Socket.Udp) != 0) {
            sock_type |= SOCK_DGRAM;
            protocol |= Options.IPPROTO_UDP;
        }

        const overlapped = if ((flags & zio.Socket.Nonblock) != 0) WSA_FLAG_OVERLAPPED else 0;
        return Winsock2.get().?.WSASocketA(family, sock_type, protocol, 0, 0, overlapped);
    }
};

///-----------------------------------------------------------------------------///
///                                API Definitions                              ///
///-----------------------------------------------------------------------------///
const AF_UNSPEC: windows.DWORD = 0;
const AF_INET: windows.DWORD = 2;
const AF_INET6: windows.DWORD = 23;
const SOCK_STREAM: windows.DWORD = 1;
const SOCK_DGRAM: windows.DWORD = 2;
const SOCK_RAW: windows.DWORD = 3;

const SOCKET_ERROR = c_int(-1);
const STATUS_SUCCESS = 0;
const WAIT_TIMEOUT: windows.DWORD = 258;
const ERROR_IO_PENDING: windows.DWORD = 997;
const SIO_GET_EXTENSION_FUNCTION_POINTER: windows.DWORD = 0xc8000006;

const WSA_OPERATION_ABORTED: windows.DWORD = 995;
const WSA_IO_INCOMPLETE: windows.DWORD = 996;
const WSA_IO_PENDING: windows.DWORD = 997;
const WSA_INVALID_HANDLE: windows.DWORD = 6;
const WSA_FLAG_OVERLAPPED: windows.DWORD = 0x01;
const WSAEACCES: windows.DWORD = 10013;
const WSAEMSGSIZE: windows.DWORD = 10040;
const WSAESHUTDOWN: windows.DWORD = 10058;
const WSAEDESTADDRREQ: windows.DWORD = 10039;
const WSAENOTINITIALIZED: windows.DWORD = 10093;
const WSAEADDRINUSE: windows.DWORD = 10048;
const WSAEADDRNOTAVAIL: windows.DWORD = 10049;
const WSAEINPROGRESS: windows.DWORD = 10036;
const WSAEMFILE: windows.DWORD = 10024;
const WSAECONNRESET: windows.DWORD = 10054;
const WSAEINTR: windows.DWORD = 10004;
const WSAEALREADY: windows.DWORD = 10037;
const WSAECONNABORTED: windows.DWORD = 10053;
const WSAECONNREFUSED: windows.DWORD = 10061;
const WSAEISCONN: windows.DWORD = 10056;
const WSAENOTCONN: windows.DWORD = 10057;
const WSAENETDOWN: windows.DWORD = 10050;
const WSAEINVAL: windows.DWORD = 10022;
const WSAEFAULT: windows.DWORD = 10014;
const WSAEDISCON: windows.DWORD = 10101;
const WSAENETUNREACH: windows.DWORD = 10051;
const WSAEHOSTUNREACH: windows.DWORD = 10065;
const WSAENETRESET: windows.DWORD = 10052;
const WSAEPROTOTYPE: windows.DWORD = 10041;
const WSAETIMEDOUT: windows.DWORD = 10060;
const WSAEWOULDBLOCK: windows.DWORD = 10035;
const WSAENOBUFS: windows.DWORD = 10055;
const WSAENOTSOCK: windows.DWORD = 10038;
const WSAEOPNOTSUPP: windows.DWORD = 10045;
const WSAENOPROTOOPT: windows.DWORD = 10042;
const WSAEAFNOTSUPPORT: windows.DWORD = 10047;
const WSAEPROTONOSUPPORT: windows.DWORD = 10043;
const WSAESOCKTNOSUPPORT: windows.DWORD = 10044;
const WSAEINVALIDPROVIDER: windows.DWORD = 10105;
const WSAEINVALIDPROCTABLE: windows.DWORD = 10104;
const WSAEPROVIDERFAILEDINIT: windows.DWORD = 10106;

const SOCKET = windows.HANDLE;
const INVALID_SOCKET = windows.INVALID_HANDLE_VALUE;
const SOCKADDR = extern union {
    in: SOCKADDR_IN,
    in6: SOCKADDR_IN6,
};

const IN_ADDR = extern struct {
    s_addr: windows.ULONG,
};

const IN6_ADDR = extern union {
    Byte: [16]windows.CHAR,
    Word: [8]windows.WORD,
};

const SOCKADDR_IN = extern struct {
    sin_family: windows.SHORT,
    sin_port: c_ushort,
    sin_addr: IN_ADDR,
    sin_zero: [8]windows.CHAR,
};

const SOCKADDR_IN6 = extern struct {
    sin6_family: windows.SHORT,
    sin6_port: c_ushort,
    sin6_flowinfo: windows.ULONG,
    sin6_addr: IN6_ADDR,
    sin6_scope_id: windows.ULONG,
};

const WSAID_ACCEPTEX = windows.GUID{
    .Data1 = 0xb5367df1,
    .Data2 = 0xcbac,
    .Data3 = 0x11cf,
    .Data4 = [_]u8{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
};

const WSAID_CONNECTEX = windows.GUID{
    .Data1 = 0x25a207b9,
    .Data2 = 0xddf3,
    .Data3 = 0x4660,
    .Data4 = [_]u8{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
};

const WSAID_GETACCEPTEXSOCKADDRS = windows.GUID{
    .Data1 = 0xb5367df2,
    .Data2 = 0xcbac,
    .Data3 = 0x11cf,
    .Data4 = [_]u8{ 0x95, 0xca, 0x0, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
};

const WSABUF = extern struct {
    len: windows.ULONG,
    buf: [*]const u8,
};

const WSAData = extern struct {
    wVersion: windows.WORD,
    wHighVersion: windows.WORD,
    iMaxSockets: c_ushort,
    iMaxUdpDg: c_ushort,
    lpVendorInfo: [*]u8,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
};

var ConnectEx: ?extern fn (
    socket: SOCKET,
    name: *const SOCKADDR,
    name_len: c_uint,
    lpSendBuffer: ?windows.PVOID,
    dwSendDataLength: windows.DWORD,
    lpdwBytesSent: ?*windows.DWORD,
    lpOverlapped: ?*windows.OVERLAPPED,
) windows.BOOL = null;

var AcceptEx: ?extern fn (
    sListenSocket: SOCKET,
    sAcceptSocket: SOCKET,
    lpOutputBuffer: ?windows.PVOID,
    dwReceiveDataLength: windows.DWORD,
    dwLocalAddressLength: windows.DWORD,
    dwRemoteAddressLength: windows.DWORD,
    lpdwBytesReceived: *windows.DWORD,
    lpOverlapped: ?*windows.OVERLAPPED,
) windows.BOOL = null;

var GetAcceptExSockaddrs: ?extern fn (
    lpOutputBuffer: windows.PVOID,
    dwReceiveDataLength: windows.DWORD,
    dwLocalAddressLength: windows.DWORD,
    dwRemoteAddressLength: windows.DWORD,
    LocalSockaddr: **SOCKADDR,
    LocalSockaddrLength: *windows.DWORD,
    RemoteSockaddr: **SOCKADDR,
    RemoteSockaddrLength: *windows.DWORD,
) void = null;

const OverlappedCompletionRoutine = extern fn (
    dwErrorCode: windows.DWORD,
    dwNumberOfBytesTransferred: windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) void;

const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: windows.ULONG_PTR,
    lpOverlapped: ?*windows.OVERLAPPED,
    Internal: windows.ULONG_PTR,
    dwNumberOfBytesTransferred: windows.DWORD,
};

extern "kernel32" stdcallcc fn GetQueuedCompletionStatusEx(
    CompletionPort: windows.HANDLE,
    lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
    ulCount: windows.ULONG,
    ulNumEntriesRemoved: *windows.ULONG,
    dwMilliseconds: windows.DWORD,
    fAlertable: windows.BOOL,
) windows.BOOL;

pub const Options = struct {
    pub const IPPROTO_TCP = 6;
    pub const IPPROTO_UDP = 17;
    pub const SOL_SOCKET = 0xffff;
    pub const SO_DEBUG = 0x0001;
    pub const TCP_NODELAY = 0x0001;
    pub const SO_LINGER = 0x0080;
    pub const SO_BROADCAST = 0x0020;
    pub const SO_REUSEADDR = 0x0004;
    pub const SO_KEEPALIVE = 0x0008;
    pub const SO_OOBINLINE = 0x0100;
    pub const SO_RCVBUF = 0x1002;
    pub const SO_RCVLOWAT = 0x1004;
    pub const SO_RCVTIMEO = 0x1006;
    pub const SO_SNDBUF = 0x1001;
    pub const SO_SNDLOWAT = 0x1003;
    pub const SO_SNDTIMEO = 0x1005;
    pub const SO_UPDATE_ACCEPT_CONTEXT = 0x700B;
    pub const SO_UPDATE_CONNECT_CONTEXT = 0x7010;
};

const Winsock2 = zuma.backend.DynamicLibrary(c"ws2_32", struct {
    closesocket: extern fn (
        socket: SOCKET,
    ) c_int,

    listen: extern fn (
        socket: SOCKET,
        backlog: c_uint,
    ) c_int,

    bind: extern fn (
        socket: SOCKET,
        addr: *const SOCKADDR,
        addr_len: c_uint,
    ) c_int,

    setsockopt: extern fn (
        socket: SOCKET,
        level: c_int,
        optname: c_int,
        optval: usize,
        optlen: c_int,
    ) c_int,

    getsockopt: extern fn (
        socket: SOCKET,
        level: c_int,
        optname: c_int,
        optval: usize,
        optlen: *c_int,
    ) c_int,

    WSAGetLastError: extern fn () c_int,
    WSACleanup: extern fn () c_int,
    WSAStartup: extern fn (
        wVersionRequested: windows.WORD,
        lpWSAData: *WSAData,
    ) c_int,

    WSAGetOverlappedResult: extern fn (
        socket: SOCKET,
        lpOverlapped: *windows.OVERLAPPED,
        lpcbTransfer: *windows.DWORD,
        fWait: windows.BOOL,
        lpdwFlags: *windows.DWORD,
    ) windows.BOOL,

    WSAIoctl: extern fn (
        socket: SOCKET,
        dwIoControlMode: windows.DWORD,
        lpvInBuffer: windows.PVOID,
        cbInBuffer: windows.DWORD,
        lpvOutBuffer: windows.PVOID,
        cbOutBuffer: windows.DWORD,
        lpcbBytesReturned: *windows.DWORD,
        lpOverlapped: ?*windows.OVERLAPPED,
        lpCompletionRoutine: ?extern fn (*windows.OVERLAPPED) usize,
    ) c_int,

    WSASocketA: extern fn (
        family: windows.DWORD,
        sock_type: windows.DWORD,
        protocol: windows.DWORD,
        lpProtocolInfo: usize,
        group: usize,
        dwFlags: windows.DWORD,
    ) SOCKET,

    WSAAccept: extern fn (
        socket: SOCKET,
        addr: *SOCKADDR,
        addrlen: *c_uint,
        lpfnCondition: ?extern fn () void,
        dwCallbackData: ?*windows.DWORD,
    ) SOCKET,

    WSAConnect: extern fn (
        socket: SOCKET,
        name: *const SOCKADDR,
        namelen: c_uint,
        lpCallerData: ?[*]const WSABUF,
        lpCalleeData: ?[*]const WSABUF,
        lpSQOS: ?*c_void,
        lpGQOS: ?*c_void,
    ) c_int,

    WSASendTo: extern fn (
        socket: SOCKET,
        lpBuffers: [*]const WSABUF,
        dwBufferCount: windows.DWORD,
        lpNumberOfBytesSent: ?*windows.DWORD,
        dwFlags: windows.DWORD,
        lpTo: ?*const SOCKADDR,
        iToLen: c_uint,
        lpOverlapped: ?*windows.OVERLAPPED,
        lpCompletionRouting: ?OverlappedCompletionRoutine,
    ) c_int,

    WSARecvFrom: extern fn (
        socket: SOCKET,
        lpBuffers: [*]WSABUF,
        dwBufferCount: windows.DWORD,
        lpNumberOfBytesRecv: ?*windows.DWORD,
        lpFlags: *windows.DWORD,
        lpFrom: ?*SOCKADDR,
        lpFromLen: ?*c_uint,
        lpOverlapped: ?*windows.OVERLAPPED,
        lpCompletionRouting: ?OverlappedCompletionRoutine,
    ) c_int,
});
