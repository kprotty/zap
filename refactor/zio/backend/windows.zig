const std = @import("std");
const windows = std.os.windows;
const posix = @import("posix.zig");
const zio = @import("../../zio.zig");

pub fn initialize() zio.InitError!void {
    const wsa_version = windows.WORD(0x0202);
    var wsa_data: WSAData = undefined;
    if (WSAStartup(wsa_version, &wsa_data) != 0)
        return zio.InitError.InvalidState;
    if (wsa_data.wVersion != wsa_version)
        return zio.InitError.InvalidState;

    const dummy_socket = WSASocketA(AF_INET, SOCK_STREAM, 0, 0, 0, 0);
    if (dummy_socket == INVALID_SOCKET)
        return zio.InitError.InvalidState;
    defer { _ = Mswsock.closesocket(dummy_socket); }

    if (AcceptEx == null)
        try findWSAFunction(dummy_socket, WSAID_ACCEPTEX, &AcceptEx);
    if (ConnectEx == null)
        try findWSAFunction(dummy_socket, WSAID_CONNECTEX, &ConnectEx);
}

pub fn cleanup() void {
    _ = WSACleanup();    
}

fn findWSAFunction(socket: SOCKET, function_guid: windows.GUID, function: var) zio.InitError!void {
    var guid = function_guid;
    var dwBytes: windows.DWORD = undefined;
    if (WSAIoctl(
        socket,
        SIO_GET_EXTENSION_FUNCTION_POINTER,
        @ptrCast(windows.PVOID, &guid),
        @sizeOf(@typeOf(guid)),
        @ptrCast(windows.PVOID, function),
        @sizeOf(@typeInfo(@typeOf(function)).Pointer.child),
        &dwBytes,
        null,
        null,
    ) != 0)
        return zio.InitError.InvalidIOFunction;
}

pub const Handle = windows.HANDLE;

pub const Buffer = struct {
    inner: WSABUF,

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This() {
            .inner = WSABUF {
                .buf = bytes.ptr,
                .len = @intCast(windows.DWORD, bytes.len),
            } 
        };
    }

    pub fn getBytes(self: @This()) []u8 {
        return self.buf[0..self.len];
    }
};

pub const Ipv4 = struct {
    inner: SOCKADDR_IN,

    pub fn from(address: u32, port: u16) @This() {
        return @This() {
            .inner = SOCKADDR_IN {
                .sin_family = AF_INET,
                .sin_port = std.mem.nativeToBig(@typeOf(port), port),
                .sin_zero = [_]u8{0} ** @sizeOf(@typeOf(SOCKADDR_IN(undefined).sin_zero)),
                .sin_addr = IN_ADDR { .s_addr = std.mem.nativeToBig(@typeOf(address), address) },
            }
        };
    }
};

pub const Ipv6 = struct {
    inner: SOCKADDR_IN6,

    pub fn from(address: u128, port: u16, flow: u32, scope: u32) @This() {
        return @This() {
            .inner = SOCKADDR_IN6 {
                .sin6_family = AF_INET6,
                .sin6_port = std.mem.nativeToBig(@typeOf(port), port),
                .sin6_flowinfo = std.mem.nativeToBig(@typeOf(flow), flow),
                .sin6_scope_id = std.mem.nativeToBig(@typeOf(scope), scope),
                .sin6_addr = IN6_ADDR { .Qword = std.mem.nativeToBig(@typeOf(address), address) },
            }
        };
    }
};

pub const Incoming = struct {
    flags: u8,
    handle: zio.Handle,
    // AccepEx requires this padding for some reason :/
    address: [@sizeOf(zio.Address) + 16]u8 align(@alignOf(zio.Address)),

    pub fn from(address: zio.Address) @This() {
        var self: @This() = undefined;
        @ptrCast(*zio.Address, &self.address[0]).* = address;
        return self;
    }

    pub fn getSocket(self: *@This()) Socket {
        return Socket.fromHandle(self.handle, self.flags);
    }

    pub fn getAddress(self: *@This()) zio.Address {
        return @ptrCast(*zio.Address, &self.address[0]).*;
    }
};

pub const Event = struct {
    inner: OVERLAPPED_ENTRY,

    pub fn getData(self: *@This(), poller: *Poller) usize {
        return self.inner.lpCompletionKey;
    }

    pub fn getResult(self: *@This()) zio.Result {
        const status = @ptrToInt(self.inner.lpOverlapped.Internal);
        return zio.Result {
            .data = self.inner.dwNumberOfBytesTransferred,
            .status = if (status == STATUS_SUCCESS) .Completed else .Retry,
        };
    }

    pub const Poller = struct {
        iocp: Handle,

        pub fn init(self: *@This()) zio.Event.Poller.InitError!void {
            self.iocp = windows.kernel32.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, undefined, 0)
                orelse return zio.Event.Poller.InitError.InvalidHandle;
        }

        pub fn close(self: *@This()) void {
            _ = windows.CloseHandle(self.iocp);
        }

        pub fn getHandle(self: @This()) zio.Handle {
            return self.iocp;
        }

        pub fn fromHandle(handle: zio.Handle) @This() {
            return @This() { .iocp = handle };
        }

        pub fn register(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            if (handle == windows.INVALID_HANDLE_VALUE)
                return zio.Event.Poller.RegisterError.InvalidHandle;
            _ = windows.kernel32.CreateIoCompletionPort(handle, self.iocp, data, 0)
                orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        pub fn reregister(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            if (handle == windows.INVALID_HANDLE_VALUE)
                return zio.Event.Poller.RegisterError.InvalidHandle;
        }

        pub fn send(self: *@This(), data: usize) zio.Event.Poller.SendError!void {
            if (self.iocp == windows.INVALID_HANDLE_VALUE)
                return zio.Event.Poller.SendError.InvalidHandle;
            if (windows.kernel32.PostQueuedCompletionStatus(self.iocp, 0, data, null) != windows.TRUE)
                return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        pub fn poll(self: *@This(), events: []Event, timeout: ?u32) zio.Event.Poller.PollError![]Event {
            var events_found: windows.ULONG = 0;
            const result = GetQueuedCompletionStatusEx(
                self.iocp,
                @ptrCast([*]OVERLAPPED_ENTRY, events.ptr),
                @intCast(windows.ULONG, events.len),
                &events_found,
                if (timeout) |t| @intCast(windows.DWORD, t) else windows.INFINITE,
                windows.FALSE,
            );
            if (result == windows.TRUE)
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
    sock_flags: u8,
    recv_flags: windows.DWORD,
    reader: windows.OVERLAPPED,
    writer: windows.OVERLAPPED,

    pub fn init(self: *@This(), flags: u8) zio.Socket.InitError!void {
        var family: windows.DWORD = 0;
        if ((flags & zio.Socket.Raw) != 0) {
            family = AF_UNSPEC;
        } else if ((flags & zio.Socket.Ipv4) != 0) {
            family = AF_INET;
        } else if ((flags & zio.Socket.Ipv6) != 0) {
            family = AF_INET6;
        }

        var protocol: windows.DWORD = 0;
        var sock_type: windows.DWORD = 0;
        if ((flags & zio.Socket.Raw) != 0) {
            sock_type = SOCK_RAW;
        } else if ((flags & zio.Socket.Tcp) != 0) {
            protocol = Mswsock.Options.IPPROTO_TCP;
            sock_type = SOCK_STREAM;
        } else if ((flags & zio.Socket.Udp) != 0) {
            protocol = Mswsock.Options.IPPROTO_UDP;
            sock_type = SOCK_DGRAM;
        }

        var wsa_flags: windows.DWORD = 0;
        if ((flags & zio.Socket.Nonblock) != 0)
            wsa_flags = WSA_FLAG_OVERLAPPED;

        self.sock_flags = flags;
        self.handle = WSASocketA(family, sock_type, protocol, 0, 0, wsa_flags);
        if (self.handle == INVALID_SOCKET) {
            return switch (WSAGetLastError()) {
                WSAENOTINITIALIZED, WSAENETDOWN, WSAEINPROGRESS, WSAEINVALIDPROVIDER, WSAEINVALIDPROCTABLE, WSAEPROVIDERFAILEDINIT => zio.Socket.InitError.InvalidState,
                WSAEAFNOTSUPPORT, WSAEFAULT, WSAEINVAL, WSAEPROTONOSUPPORT, WSAEPROTOTYPE, WSAESOCKTNOSUPPORT => zio.Socket.InitError.InvalidValue,
                WSAEMFILE, WSAENOBUFS => zio.Socket.InitError.OutOfResources,
                else => unreachable,
            };
        }
    }

    pub fn close(self: *@This()) void {
        _ = Mswsock.closesocket(self.handle);
    }

    pub fn getHandle(self: @This()) zio.Handle {
        return self.handle;
    }

    pub fn fromHandle(handle: zio.Handle, flags: u8) @This() {
        var self: @This() = undefined;
        self.sock_flags = flags;
        self.handle = handle;
        return self;
    }

    pub fn isReadable(self: *const @This(), event: Event) bool {
        return event.lpOverlapped == &self.reader;
    }

    pub fn isWriteable(self: *const @This(), event: Event) bool {
        return event.lpOverlapped == &self.writer;
    }

    pub const Linger = extern struct {
        l_onoff: c_ushort,
        l_linger: c_ushort,
    };

    pub fn setOption(self: *@This(), option: zio.Socket.Option) zio.Socket.OptionError!void {
        var option_val = option;
        if (posix.Socket.socketOption(true, self.handle, &option_val, Mswsock.setsockopt, Mswsock.Options) == 0)
            return;
        return switch (WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN, WSAEINPROGRESS => zio.Socket.OptionError.InvalidState,
            WSAENETRESET, WSAENOTCONN, WSAENOTSOCK => zio.Socket.OptionError.InvalidHandle,
            WSAEINVAL, WSAENOPROTOOPT => zio.Socket.OptionError.InvalidValue,
            WSAEFAULT => unreachable,
            else => unreachable,
        };
    }

    pub fn getOption(self: *@This(), option: *zio.Socket.Option) zio.Socket.OptionError!void {
        if (posix.Socket.socketOption(false, self.handle, option, Mswsock.getsockopt, Mswsock.Options) == 0)
            return;
        return switch (WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN, WSAEINPROGRESS => zio.Socket.OptionError.InvalidState,
            WSAEFAULT, WSAENOPROTOOPT => zio.Socket.OptionError.InvalidValue,
            WSAENOTSOCK => zio.Socket.OptionError.InvalidHandle,
            WSAEINVAL => unreachable,
            else => unreachable,
        };
    }

    pub fn bind(self: *@This(), address: *const zio.Address) zio.Socket.BindError!void {
        if (Mswsock.bind(self.handle, @ptrCast(*const SOCKADDR, &address.ip), address.len) == 0)
            return;
        return switch (WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN => zio.Socket.BindError.InvalidState,
            WSAEADDRNOTAVAIL, WSAEFAULT => zio.Socket.BindError.InvalidAddress,
            WSAEADDRINUSE => zio.Socket.BindError.AddressInUse,
            WSAENOTSOCK => zio.Socket.BindError.InvalidHandle,
            WSAENOBUFS => zio.Socket.BindError.OutOfResources,
            else => unreachable,
        };
    }

    pub fn listen(self: *@This(), backlog: u16) zio.Socket.ListenError!void {
        if (Mswsock.listen(self.handle, backlog) == 0)
            return;
        return switch (WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN, WSAEADDRINUSE, WSAEINPROGRESS, WSAEINVAL => zio.Socket.ListenError.InvalidState,
            WSAEISCONN, WSAEMFILE, WSAENOTSOCK, WSAEOPNOTSUPP => zio.Socket.ListenError.InvalidHandle,
            WSAENOBUFS => zio.Socket.ListenError.OutOfResources,
            else => unreachable,
        };
    }

    pub fn connect(self: *@This(), address: *const zio.Address) zio.Result {
        if ((self.sock_flags & zio.Socket.Nonblock) == 0) {
            if (Mswsock.connect(self.handle, @ptrCast(*const SOCKADDR, &address.ip), address.len) == 0)
                return zio.Result { .status = .Completed, .data = 0 };
            std.debug.warn("\n{}\n", WSAGetLastError());
            return switch (WSAGetLastError()) {
                WSAENOTINITIALIZED, WSAENETDOWN, WSAEADDRINUSE, WSAEINTR,
                WSAEINPROGRESS, WSAEALREADY, WSAEADDRNOTAVAIL, WSAEAFNOTSUPPORT,
                WSAECONNREFUSED, WSAEFAULT, WSAEINVAL, WSAEISCONN, WSAENETUNREACH,
                WSAEHOSTUNREACH, WSAENOBUFS, WSAENOTSOCK, WSAETIMEDOUT, WSAEWOULDBLOCK, WSAEACCES,
                    => zio.Result { .status = .Error, .data = 0 },
                else => unreachable,
            };
        }

        const connectEx = ConnectEx orelse return zio.Result { .status = .Error, .data = 0 };
        @memset(@ptrCast([*]u8, &self.writer), 0, @sizeOf(windows.OVERLAPPED));
        return getResultFrom(0, connectEx(
            self.handle,
            @ptrCast(*const SOCKADDR, &address.ip),
            address.len,
            null,   // no buffer to send after connecting
            0,      // sizeof buffer to send doesnt exist
            null,   // not sending data so no recv len ptr
            &self.writer,
        ));
    }

    pub fn accept(self: *@This(), incoming: *Incoming) zio.Result {
        const address = @ptrCast(*zio.Address, &incoming.address);
        if ((self.sock_flags & zio.Socket.Nonblock) == 0) {
            if (Mswsock.accept(self.handle, @ptrCast(*SOCKADDR, &address.ip), address.len) == 0)
                return zio.Result { .status = .Completed, .data = 0 };
            return switch (WSAGetLastError()) {
                WSAENOTINITIALIZED, WSAECONNRESET, WSAEFAULT,
                WSAEINTR, WSAEINVAL, WSAEINPROGRESS, WSAEMFILE,
                WSAENETDOWN, WSAENOBUFS, WSAENOTSOCK, WSAEOPNOTSUPP, WSAEWOULDBLOCK,
                    => zio.Result { .status = .Error, .data = 0 },
                else => unreachable,
            };
        }

        // need to create the socket before hand.
        var listen_socket: @This() = undefined;
        _ = listen_socket.init(self.sock_flags) catch return zio.Result { .status = .Error, .data = 0 };
        incoming.flags = self.sock_flags;
        incoming.handle = listen_socket.getHandle();

        const acceptEx = AcceptEx orelse return zio.Result { .status = .Error, .data = 0 };
        @memset(@ptrCast([*]u8, &self.reader), 0, @sizeOf(windows.OVERLAPPED));
        return getResultFrom(0, acceptEx(
            incoming.handle,
            self.handle,
            @ptrCast(windows.PVOID, &incoming.address),
            0, // dont receive any data
            0, // dont retrive local address
            @intCast(windows.DWORD, incoming.getAddress().len),
            &self.recv_flags,
            &self.reader,
        ));
    }

    pub fn recv(self: *@This(), address: ?*zio.Address, buffers: []Buffer) zio.Result {
        return self.performIO(&self.reader, address, buffers, performRead);
    }

    pub fn send(self: *@This(), address: ?*const zio.Address, buffers: []const Buffer) zio.Result {
        return self.performIO(&self.writer, address, buffers, performWrite);
    }

    fn getResultFrom(data: u32, result: windows.BOOL) zio.Result {
        if (result == windows.TRUE)
            return zio.Result { .status = .Completed, .data = data };
        const wsa_error = @intCast(windows.DWORD, WSAGetLastError());
        if (wsa_error == ERROR_IO_PENDING or wsa_error == WSA_IO_PENDING)
            return zio.Result { .status = .Retry, .data = 0 };
        return zio.Result { .status = .Error, .data = 0 };
    }

    fn performRead(self: *@This(), overlapped: ?*windows.OVERLAPPED, address: ?*zio.Address, buffers: []Buffer, transferred: *windows.DWORD) c_int {
        self.recv_flags = 0;
        return WSARecvFrom(
            self.handle,
            @ptrCast([*]WSABUF, buffers.ptr),
            @intCast(windows.DWORD, buffers.len),
            transferred,
            &self.recv_flags,
            @ptrCast(?*SOCKADDR, if (address) |addr| &addr.ip else null),
            if (address) |addr| &addr.len else null,
            overlapped,
            null,
        );
    }

    fn performWrite(self: *@This(), overlapped: ?*windows.OVERLAPPED, address: ?*const zio.Address, buffers: []const Buffer, transferred: *windows.DWORD) c_int {
        return WSASendTo(
            self.handle,
            @ptrCast([*]const WSABUF, buffers.ptr),
            @intCast(windows.DWORD, buffers.len),
            transferred,
            0, // no receive flags
            @ptrCast(?*const SOCKADDR, if (address) |addr| &addr.ip else null),
            if (address) |addr| addr.len else 0,
            overlapped,
            null,
        );
    }

    fn performIO(self: *@This(), overlapped: *windows.OVERLAPPED, address: var, buffers: var, perform: var) zio.Result {
        // return early for no buffers
        if (buffers.len == 0)
            return zio.Result { .status = .Completed, .data = 0 };

        // prepare the overlapped pointer if necessary (by checking if the socket is non-blocking)
        var overlapped_ptr: ?*windows.OVERLAPPED = null;
        const is_non_blocking = (self.sock_flags & zio.Socket.Nonblock) != 0;
        if (is_non_blocking) {
            overlapped_ptr = overlapped;
            @memset(@ptrCast([*]u8, overlapped_ptr), 0, @sizeOf(windows.OVERLAPPED));
        }

        // perform the actual io & use the `bytes_transferred` if socket isnt non-blocking
        var bytes_transferred: windows.DWORD = undefined;
        const io_result = perform(self, overlapped_ptr, address, buffers, &bytes_transferred);
        const result = if (io_result == SOCKET_ERROR) windows.BOOL(windows.TRUE) else windows.FALSE;
        return getResultFrom(if (is_non_blocking) bytes_transferred else 0, result);
    }
};

///-----------------------------------------------------------------------------///
///                                API Definitions                              ///
///-----------------------------------------------------------------------------///

const AF_UNSPEC: windows.DWORD = 0;
const AF_INET: windows.DWORD = 2;
const AF_INET6: windows.DWORD = 6;
const SOCK_STREAM: windows.DWORD = 1;
const SOCK_DGRAM: windows.DWORD = 2;
const SOCK_RAW: windows.DWORD = 3;

const SOCKET_ERROR = -1;
const STATUS_SUCCESS = 0;
const WAIT_TIMEOUT: windows.DWORD = 258;
const ERROR_IO_PENDING: windows.DWORD = 997;
const SIO_GET_EXTENSION_FUNCTION_POINTER: windows.DWORD = 0xc8000006;

const WSA_IO_PENDING: windows.DWORD = 997;
const WSA_INVALID_HANDLE: windows.DWORD = 6;
const WSA_FLAG_OVERLAPPED: windows.DWORD = 0x01;
const WSAEACCES: windows.DWORD = 10013;
const WSAEMSGSIZE: windows.DWORD = 10040;
const WSAENOTINITIALIZED: windows.DWORD = 10093;
const WSAEADDRINUSE: windows.DWORD = 10048;
const WSAEADDRNOTAVAIL: windows.DWORD = 10049;
const WSAEINPROGRESS: windows.DWORD = 10036;
const WSAEMFILE: windows.DWORD = 10024;
const WSAECONNRESET: windows.DWORD = 10054;
const WSAEINTR: windows.DWORD = 10004;
const WSAEALREADY: windows.DWORD = 10037;
const WSAECONNREFUSED: windows.DWORD = 10061;
const WSAEISCONN: windows.DWORD = 10056;
const WSAENOTCONN: windows.DWORD = 10057;
const WSAENETDOWN: windows.DWORD = 10050;
const WSAEINVAL: windows.DWORD = 10022;
const WSAEFAULT: windows.DWORD = 10014;
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
const SOCKADDR = extern struct {
    sa_family: c_ushort,
    sa_data: [14]windows.CHAR,
};

const IN_ADDR = extern struct {
    s_addr: windows.ULONG,
};

const IN6_ADDR = extern union {
    Byte: [16]windows.CHAR,
    Word: [8]windows.WORD,
    Qword: u128,
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

const WSAID_ACCEPTEX = windows.GUID {
    .Data1 = 0xb5367df1,
    .Data2 = 0xcbac,
    .Data3 = 0x11cf,
    .Data4 = [_]u8 { 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
};

const WSAID_CONNECTEX = windows.GUID {
    .Data1 = 0x25a207b9,
    .Data2 = 0xddf3,
    .Data3 = 0x4660,
    .Data4 = [_]u8 { 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
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

var ConnectEx: ?extern fn(
    socket: SOCKET,
    name: *const SOCKADDR,
    name_len: c_int,
    lpSendBuffer: ?windows.PVOID,
    dwSendDataLength: windows.DWORD,
    lpdwBytesSent: ?*windows.DWORD,
    lpOverlapped: ?*windows.OVERLAPPED,
) windows.BOOL = undefined;

var AcceptEx: ?extern fn(
    sListenSocket: SOCKET,
    sAcceptSocket: SOCKET,
    lpOutputBuffer: ?windows.PVOID,
    dwReceiveDataLength: windows.DWORD,
    dwLocalAddressLength: windows.DWORD,
    dwRemoteAddressLength: windows.DWORD,
    lpdwBytesReceived: *windows.DWORD,
    lpOverlapped: ?*windows.OVERLAPPED,
) windows.BOOL = undefined;

const OverlappedCompletionRoutine = extern fn(
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

const Mswsock = struct {
    pub extern "ws2_32" stdcallcc fn closesocket(
        socket: SOCKET,
    ) c_int;

    pub extern "ws2_32" stdcallcc fn listen(
        socket: SOCKET,
        backlog: c_int,
    ) c_int;

    pub extern "ws2_32" stdcallcc fn bind(
        socket: SOCKET,
        addr: *const SOCKADDR,
        addr_len: c_int,
    ) c_int;

    pub extern "ws2_32" stdcallcc fn connect(
        socket: SOCKET,
        addr: *const SOCKADDR,
        addr_len: c_int,
    ) c_int;

    pub extern "ws2_32" stdcallcc fn accept(
        socket: SOCKET,
        addr: *SOCKADDR,
        addr_len: c_int,
    ) c_int;

    pub extern "ws2_32" stdcallcc fn setsockopt(
        socket: SOCKET,
        level: c_int,
        optname: c_int,
        optval: usize,
        optlen: c_int,
    ) c_int;

    pub extern "ws2_32" stdcallcc fn getsockopt(
        socket: SOCKET,
        level: c_int,
        optname: c_int,
        optval: usize,
        optlen: *c_int,
    ) c_int;

    pub const Options = struct {
        pub const IPPROTO_TCP: c_int = 6;
        pub const IPPROTO_UDP: c_int = 17;
        pub const SOL_SOCKET: c_int = 0xffff;
        pub const SO_DEBUG: c_int = 0x0001;
        pub const TCP_NODELAY: c_int = 0x0001;
        pub const SO_LINGER: c_int = 0x0080;
        pub const SO_BROADCAST: c_int = 0x0020;
        pub const SO_REUSEADDR: c_int = 0x0004;
        pub const SO_KEEPALIVE: c_int = 0x0008;
        pub const SO_OOBINLINE: c_int = 0x0100;
        pub const SO_RCVBUF: c_int = 0x1002;
        pub const SO_RCVLOWAT: c_int = 0x1004;
        pub const SO_RCVTIMEO: c_int = 0x1006;
        pub const SO_SNDBUF: c_int = 0x1001;
        pub const SO_SNDLOWAT: c_int = 0x1003;
        pub const SO_SNDTIMEO: c_int = 0x1005;
    };
};

extern "ws2_32" stdcallcc fn WSAGetLastError() c_int;
extern "ws2_32" stdcallcc fn WSACleanup() c_int;
extern "ws2_32" stdcallcc fn WSAStartup(
    wVersionRequested: windows.WORD,
    lpWSAData: *WSAData,
) c_int;

extern "ws2_32" stdcallcc fn WSAIoctl(
    socket: SOCKET,
    dwIoControlMode: windows.DWORD,
    lpvInBuffer: windows.PVOID,
    cbInBuffer: windows.DWORD,
    lpvOutBuffer: windows.PVOID,
    cbOutBuffer: windows.DWORD,
    lpcbBytesReturned: *windows.DWORD,
    lpOverlapped: ?*windows.OVERLAPPED,
    lpCompletionRoutine: ?extern fn(*windows.OVERLAPPED) usize,
) c_int;

extern "ws2_32" stdcallcc fn WSASocketA(
    family: windows.DWORD,
    sock_type: windows.DWORD,
    protocol: windows.DWORD,
    lpProtocolInfo: usize,
    group: usize,
    dwFlags: windows.DWORD,
) SOCKET;

extern "ws2_32" stdcallcc fn WSASendTo(
    socket: SOCKET,
    lpBuffers: [*]const WSABUF,
    dwBufferCount: windows.DWORD,
    lpNumberOfBytesSent: ?*windows.DWORD,
    dwFlags: windows.DWORD,
    lpTo: ?*const SOCKADDR,
    iToLen: c_int,
    lpOverlapped: ?*windows.OVERLAPPED,
    lpCompletionRouting: ?OverlappedCompletionRoutine,
) c_int;

extern "ws2_32" stdcallcc fn WSARecvFrom(
    socket: SOCKET,
    lpBuffers: [*]WSABUF,
    dwBufferCount: windows.DWORD,
    lpNumberOfBytesRecv: ?*windows.DWORD,
    lpFlags: *windows.DWORD,
    lpFrom: ?*SOCKADDR,
    lpFromLen: ?*c_int,
    lpOverlapped: ?*windows.OVERLAPPED,
    lpCompletionRouting: ?OverlappedCompletionRoutine,
) c_int;