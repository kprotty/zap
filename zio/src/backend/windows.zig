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
        return @This() {
            .inner = WSABUF {
                .buf = bytes.ptr,
                .len = @intCast(windows.DWORD, bytes.len),
            }
        };
    }
};

pub const IncomingPadding = 16;
pub const SockAddr = extern struct {
    pub const Ipv4 = SOCKADDR_IN;
    pub const Ipv6 = SOCKADDR_IN6;

    inner: SOCKADDR,

    pub fn fromIpv4(address: u32, port: u16) @This() {
        return @This() {
            .inner = SOCKADDR {
                .in = Ipv4 {
                    .sin_family = AF_INET,
                    .sin_zero = [_]u8{0} ** 8,
                    .sin_addr = IN_ADDR { .s_addr = address },
                    .sin_port = @intCast(c_ushort, std.mem.nativeToBig(u16, port)),
                },
            },
        };
    }

    pub fn fromIpv6(address: u128, port: u16, flowinfo: u32, scope: u32) @This() {
        return @This() {
            .inner = SOCKADDR {
                .in6 = Ipv6 {
                    .sin6_family = AF_INET6,
                    .sin6_scope_id = scope,
                    .sin6_flowinfo = flowinfo,
                    .sin6_addr = IN6_ADDR { .Qword = address },
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
            const handle = windows.kernel32.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, undefined, 0)
                orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            return @This() { .iocp = handle };
        }

        pub fn close(self: *@This()) void {
            _ = windows.CloseHandle(self.iocp);
        }

        pub fn fromHandle(handle: zio.Handle) @This() {
            return @This() { .iocp = handle };
        }

        pub fn getHandle(self: @This()) zio.Handle {
            return self.iocp;
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
                if (timeout) |t| @intCast(windows.DWORD, t) else windows.INFINITE,
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
        var family: windows.DWORD = 0;
        var sock_type: windows.DWORD = 0;
        var protocol: windows.DWORD = 0;

        // convert the socket flags
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
            protocol |= Mswsock.Options.IPPROTO_TCP;
        } else if ((flags & zio.Socket.Udp) != 0) {
            sock_type |= SOCK_DGRAM;
            protocol |= Mswsock.Options.IPPROTO_UDP;
        }  

        var self: @This() = undefined;
        if ((flags & zio.Socket.Nonblock) == 0) {
            self.handle = Mswsock.socket(family, sock_type, protocol);
        } else {
            self.handle = WSASocketA(family, sock_type, protocol, 0, 0, WSA_FLAG_OVERLAPPED);
            if (self.handle != INVALID_SOCKET)
                self.handle = @intToPtr(Handle, @ptrToInt(self.handle) | is_overlapped);
        }
        
        if (self.handle != INVALID_SOCKET)
            return self;
        return switch (WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN, WSAEINPROGRESS, WSAEINVALIDPROVIDER, WSAEINVALIDPROCTABLE, WSAEPROVIDERFAILEDINIT => zio.Socket.Error.InvalidState,
            WSAEAFNOTSUPPORT, WSAEFAULT, WSAEINVAL, WSAEPROTONOSUPPORT, WSAEPROTOTYPE, WSAESOCKTNOSUPPORT => zio.Socket.Error.InvalidValue,
            WSAEMFILE, WSAENOBUFS => zio.Socket.Error.OutOfResources,
            else => unreachable,
        };
    }

    pub fn close(self: *@This()) void {
        _ = Mswsock.closesocket(self.handle);
    }

    pub fn fromHandle(handle: zio.Handle) @This() {
        var self: @This() = undefined;
        self.handle = handle;
        return self;
    }

    const is_overlapped = usize(1);
    pub fn getHandle(self: @This()) zio.Handle {
        return @intToPtr(zio.Handle, @ptrToInt(self.handle) & ~is_overlapped);
    }

    var init_error = zync.Lazy(WSAInitialize).new();
    fn WSAInitialize() zio.Socket.Error!void {
        const wsa_version = windows.WORD(0x0202);
        var wsa_data: WSAData = undefined;
        if (WSAStartup(wsa_version, &wsa_data) != 0)
            return zio.Socket.Error.InvalidState;
        if (wsa_data.wVersion != wsa_version)
            return zio.Socket.Error.InvalidState;

        const dummy_socket = Mswsock.socket(AF_INET, SOCK_STREAM, 0);
        if (dummy_socket == INVALID_SOCKET)
            return zio.Socket.Error.InvalidState;
        defer { _ = Mswsock.closesocket(dummy_socket); }

        if (AcceptEx == null)
            _ = findWSAFunction(dummy_socket, WSAID_ACCEPTEX, &AcceptEx) catch |err| return err;
        if (ConnectEx == null)
            _ = findWSAFunction(dummy_socket, WSAID_CONNECTEX, &ConnectEx) catch |err| return err;
    }

    fn findWSAFunction(socket: SOCKET, function_guid: windows.GUID, function: var) zio.Socket.Error!void {
        var guid = function_guid;
        var dwBytes: windows.DWORD = undefined;
        const result = WSAIoctl(
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

    pub const Linger = extern struct {
        l_onoff: c_ushort,
        l_linger: c_ushort,
    };

    pub fn setOption(self: *@This(), option: zio.Socket.Option) zio.Socket.OptionError!void {
        var option_val = option;
        if (posix.Socket.socketOption(self.getHandle(), &option_val, Mswsock.setsockopt, Mswsock.Options) == 0)
            return;
        return switch (WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN, WSAEINPROGRESS => zio.Socket.OptionError.InvalidState,
            WSAENETRESET, WSAENOTCONN, WSAENOTSOCK => zio.Socket.OptionError.InvalidHandle,
            WSAEINVAL, WSAENOPROTOOPT => zio.Socket.OptionError.InvalidValue,
            WSAEFAULT => unreachable,
            else => unreachable,
        };
    }

    pub fn getOption(self: @This(), option: *zio.Socket.Option) zio.Socket.OptionError!void {
        if (posix.Socket.socketOption(self.getHandle(), option, Mswsock.getsockopt, Mswsock.Options) == 0)
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
        if (Mswsock.bind(self.getHandle(), zuma.mem.ptrCast(*const SOCKADDR, &address.sockaddr), address.length) == 0)
            return;
        return switch (WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN, WSAENOBUFS => zio.Socket.BindError.InvalidState,
            WSAEADDRNOTAVAIL, WSAEFAULT => zio.Socket.BindError.InvalidAddress,
            WSAEADDRINUSE => zio.Socket.BindError.AddressInUse,
            WSAENOTSOCK => zio.Socket.BindError.InvalidHandle,
            else => unreachable,
        };
    }

    pub fn listen(self: *@This(), backlog: c_uint) zio.Socket.ListenError!void {
        if (Mswsock.listen(self.getHandle(), backlog) == 0)
            return;
        return switch (WSAGetLastError()) {
            WSAENOTINITIALIZED, WSAENETDOWN, WSAENOBUFS, WSAEINPROGRESS, WSAEINVAL => zio.Socket.ListenError.InvalidState,
            WSAEISCONN, WSAEMFILE, WSAENOTSOCK, WSAEOPNOTSUPP => zio.Socket.ListenError.InvalidHandle,
            WSAEADDRINUSE => zio.Socket.ListenError.AddressInUse,
            else => unreachable,
        };
    }

    pub fn connect(self: *@This(), address: *const zio.Address, token: usize) zio.Socket.ConnectError!void {
        return switch (error_code: {
            switch (try self.getOverlappedResult(&self.writer, token)) {
                .Completed => |_| return,
                .Error => |code| break :error_code code,
                .Retry => |overlapped| {
                    const handle = self.getHandle();
                    const addr = zuma.mem.ptrCast(*const SOCKADDR, address.sockaddr);
                    if (overlapped) |ov| {
                        if ((ConnectEx.?)(handle, addr, address.length, null, 0, null, ov) == windows.TRUE)
                            return;
                    } else {
                        if (Mswsock.connect(handle, addr, address.length) == 0)
                            return;
                    }
                    break :error_code WSAGetLastError();
                },
            }
        }) {
            0 => unreachable,
            WSAENOTINITIALIZED, WSAENETDOWN, WSAENETUNREACH, WSAENOBUFS => zio.Socket.ConnectError.InvalidState,
            WSAEADDRINUSE, WSAECONNREFUSED, WSAEHOSTUNREACH => zio.Socket.ConnectError.Refused,
            WSAEAFNOTSUPPORT, WSAENOTSOCK => zio.Socket.ConnectError.InvalidHandle,
            WSAEADDRNOTAVAIL, WSAEINVAL => zio.Socket.ConnectError.InvalidAddress,
            WSAEALREADY, WSAEISCONN => zio.Socket.ConnectError.AlreadyConnected,
            WSAETIMEDOUT => zio.Socket.ConnectError.TimedOut,
            else => unreachable,
        };
    }

    pub fn accept(self: *@This(), flags: zio.Socket.Flags, incoming: *zio.Address.Incoming, token: usize) zio.Socket.AcceptError!void {
        
    }

    pub fn recvmsg(self: *@This(), address: ?*zio.Address, buffers: []Buffer, token: usize) zio.Socket.DataError!usize {
        
    }

    pub fn sendmsg(self: *@This(), address: ?*const zio.Address, buffers: []const Buffer, token: usize) zio.Socket.DataError!usize {
        
    }

    const OverlappedResult = union(enum) {
        Error: c_int,
        Completed: usize,
        Retry: ?*windows.OVERLAPPED,
    };

    fn getOverlappedResult(self: *@This(), overlapped: *windows.OVERLAPPED, token: usize) zio.Error!OverlappedResult {
        if (token == @ptrToInt(overlapped)) {
            if (overlapped.Internal == STATUS_SUCCESS)
                return OverlappedResult { .Completed = overlapped.InternalHigh };
            return OverlappedResult { .Error = @intCast(c_int, overlapped.Internal) };
        } else if (token != 0) {
            return zio.ErrorInvalidToken;
        }

        const use_overlapped = (@ptrToInt(self.handle) & is_overlapped) != 0;
        if (use_overlapped) 
            @memset(@ptrCast([*]u8, overlapped), 0, @sizeOf(windows.OVERLAPPED));
        return OverlappedResult { .Retry = if (use_overlapped) overlapped else null };
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
    name_len: c_uint,
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
    pub extern "ws2_32" stdcallcc fn socket(
        domain: windows.DWORD,
        sock_type: windows.DWORD,
        protocol: windows.DWORD,
    ) SOCKET;

    pub extern "ws2_32" stdcallcc fn closesocket(
        socket: SOCKET,
    ) c_int;

    pub extern "ws2_32" stdcallcc fn listen(
        socket: SOCKET,
        backlog: c_uint,
    ) c_int;

    pub extern "ws2_32" stdcallcc fn bind(
        socket: SOCKET,
        addr: *const SOCKADDR,
        addr_len: c_uint,
    ) c_int;

    pub extern "ws2_32" stdcallcc fn connect(
        socket: SOCKET,
        addr: *const SOCKADDR,
        addr_len: c_uint,
    ) c_int;

    pub extern "ws2_32" stdcallcc fn accept(
        socket: SOCKET,
        addr: *SOCKADDR,
        addr_len: c_uint,
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