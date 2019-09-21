const std = @import("std");
const posix = @import("posix.zig");
const zio = @import("../../zio.zig");
const zync = @import("../../../zync/zync.zig");

const windows = std.os.windows;

pub const Handle = windows.HANDLE;

pub const Buffer = struct {
    inner: WSABUF,

    pub fn getBytes(self: @This()) []u8 {
        return self.inner.buf[0..self.inner.len];
    }

    pub fn fromBytes(bytes: []u8) @This() {
        return @This() {
            .inner = WSABUF {
                .buf = bytes.ptr,
                .len = @intCast(windows.DWORD, bytes.len),
            }
        };
    }
};

pub const ConstBuffer = struct {
    inner: WSABUF,

    pub fn getBytes(self: @This()) []const u8 {
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

pub const Socket = struct {
    handle: Handle,
    reader: windows.OVERLAPPED,
    writer: windows.OVERLAPPED,

    pub fn new(flags: zio.Socket.Flags) zio.Socket.Error!@This() {
        if (init_error.get()) |err|
            return err;
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

    var init_error = zync.Lazy(WSAInitialize);
    fn WSAInitialize() ?zio.Socket.Error {
        const wsa_version = windows.WORD(0x0202);
        var wsa_data: WSAData = undefined;
        if (WSAStartup(wsa_version, &wsa_data) != 0)
            return zio.Socket.Error.InvalidInitialize;
        if (wsa_data.wVersion != wsa_version)
            return zio.Socket.Error.InvalidInitialize;

        const dummy_socket = Mswsock.socket(AF_INET, SOCK_STREAM, 0);
        if (dummy_socket == INVALID_SOCKET)
            return zio.Socket.Error.InvalidInitialize;
        defer { _ = Mswsock.closesocket(dummy_socket); }

        if (AcceptEx == null)
            _ = findWSAFunction(dummy_socket, WSAID_ACCEPTEX, &AcceptEx) catch |err| return err;
        if (ConnectEx == null)
            _ = findWSAFunction(dummy_socket, WSAID_CONNECTEX, &ConnectEx) catch |err| return err;
        return null;
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
            return zio.Socket.Error.InvalidInitialize;
    }

    pub const Linger = extern struct {
        l_onoff: c_ushort,
        l_linger: c_ushort,
    };

    pub fn setOption(self: *@This(), option: zio.Socket.Option) zio.Socket.OptionError!void {
        var option_val = option;
        if (posix.socketOption(self.getHandle(), option_val, Mswsock.setsockopt, Mswsock.Options) == 0)
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
        if (posix.socketOption(self.getHandle(), option_val, Mswsock.getsockopt, Mswsock.Options) == 0)
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
        if (Mswsock.bind(self.getHandle(), @ptrCast(*const SOCKADDR, &address.sockaddr), address.length) == 0)
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
            switch (self.getOverlappedResult(&self.writer, token)) {
                .Completed => |_| return,
                .Error => |code| break :error_code code,
                .Retry => |overlapped| {
                    const handle = self.getHandle();
                    const addr = @ptrCast(*const SOCKADDR, address.sockaddr);
                    if (switch (overlapped) {
                        null => Mswsock.connect(handle, addr, address.length) == 0,
                        else => (ConnectEx.?)(handle, addr, address.length, null, 0, null, overlapped) == windows.TRUE,
                    }) return;
                    break :error_code WSAGetLastError();
                },
            }
        }) {
            0 => unreachable,
            // TODO
            else => unreachable,
        };
    }

    pub fn accept(self: *@This(), flags: zio.Socket.Flags, incoming: *Incoming, token: usize) zio.Socket.AcceptError!void {
        
    }

    pub fn recv(self: *@This(), address: ?*zio.Address, buffers: []Buffer, token: usize) zio.Socket.DataError!usize {
        
    }

    pub fn send(self: *@This(), address: ?*const zio.Address, buffers: []const ConstBuffer, token: usize) zio.Socket.DataError!usize {
        
    }

    const OverlappedResult = union(enum) {
        Error: c_int,
        Completed: usize,
        Retry: ?*windows.OVERLAPPED,
    };

    fn getOverlappedResult(self: *@This(), overlapped: *windows.OVERLAPPED, token: usize) OverlappedResult {
        std.debug.assert(token == 0 or token == @ptrToInt(overlapped));
        if (token == @ptrToInt(overlapped)) {
            if (overlapped.Internal == STATUS_SUCCESS)
                return OverlappedResult { .Completed = overlapped.InternalHigh };
            return OverlappedResult { .Error = @intCast(c_int, overlapped.Internal) };
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
    pub extern "ws2_32" stdcallcc fn socket(
        domain: windows.DWORD,
        sock_type: windows.DWORD,
        protocol: windows.DWORD,
    ) c_int;

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