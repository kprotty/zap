const std = @import("std");
const windows = std.os.windows;
const zio = @import("../zio.zig");

pub const Handle = windows.HANDLE;

pub fn Initialize() zio.InitError!void {
    // initialize winsock
    var wsa_data: WSAData = undefined;
    const wsa_version = windows.WORD(0x0202); // winsock 2.2
    if (WSAStartup(wsa_version, &wsa_data) != 0 or wsa_data.wVersion != wsa_version)
        return zio.InitError.InvalidSystemState;

    // For loading WSA functions at runtime (required by winapi)
    const WSA = struct {
        pub fn findFunction(sock: Handle, id: windows.GUID, function: var) zio.InitError!void {
            var guid = id;
            var dwBytes: windows.DWORD = undefined;
            if (WSAIoctl(
                sock,
                SIO_GET_EXTENSION_FUNCTION_POINTER,
                @ptrCast(windows.PVOID, &guid),
                @sizeOf(@typeOf(guid)),
                @ptrCast(windows.PVOID, function),
                @sizeOf(@typeInfo(function).Pointer.child),
                &dwBytes,
                null,
                null,
            ) != 0)
                return zio.InitError.InvalidIOFunction;
        }
    };

    // Find AcceptEx and ConnectEx using WSAIoctl
    if (AcceptEx == null or ConnectEx == null) {  
        const dummy_socket = socket(AF_INET, SOCK_STREAM, 0);
        if (dummy_socket == windows.INVALID_HANDLE_VALUE)
            return windows.unexpectedError(windows.kernel32.GetLastError());
        defer closesocket(dummy_socket);
        try WSA.findFunction(dummy_socket, WSAID_ACCEPTEX, &AcceptEx);
        try WSA.findFunction(dummy_socket, WSAID_CONNECTEX, &ConnectEx);
    }
}

pub fn Cleanup() void {
    _ = WSACleanup();
}

pub const Buffer = packed struct {
    inner: WSABUF,

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This() {
            .inner = WSABUF {
                .buf = bytes.ptr,
                .len = @intCast(windows.DWORD, clamp(windows.DWORD, bytes.len)),
            }
        };
    }

    pub fn getBytes(self: @This()) []u8 {
       return self.inner.buf[0..self.inner.len];
    }
};

pub const EventPoller = struct {
    iocp: Handle,

    pub fn getHandle(self: @This()) Handle {
        return self.iocp;
    }

    pub fn fromHandle(handle: Handle) @This() {
        return @This() { .iocp = handle };
    }

    pub fn init(self: *@This()) zio.EventPoller.Error!void {
        self.iocp = windows.kernel32.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, undefined, 0)
            orelse return zio.EventPoller.Error.InvalidHandle;
    }

    pub fn close(self: *@This()) void {
        _ = windows.CloseHandle(self.iocp);
        self.iocp = windows.INVALID_HANDLE_VALUE;
    }

    pub fn register(self: *@This(), handle: Handle, flags: u32, data: usize) zio.EventPoller.RegisterError!void {
        if (handle == windows.INVALID_HANDLE_VALUE)
            return zio.EventPoller.RegisterError.InvalidHandle;
        _ = windows.kernel32.CreateIoCompletionPort(handle, self.iocp, @ptrCast(windows.ULONG_PTR, data), 0)
            orelse return windows.unexpectedError(windows.kernel32.GetLastError());
    }

    pub fn reregister(self: *@This(), handle: Handle, flags: u32, data: usize) zio.EventPoller.RegisterError!void {
        if (handle == windows.INVALID_HANDLE_VALUE)
            return zio.EventPoller.RegisterError.InvalidHandle;
    }

    pub fn notify(self: *@This(), data: usize) zio.EventPoller.NotifyError!void {
        if (self.iocp == windows.INVALID_HANDLE_VALUE)
            return zio.EventPoller.PollError.InvalidHandle;
        if (windows.kernel32.PostQueuedCompletionStatus(self.iocp, 0, @intToPtr(windows.ULONG_PTR, data), null) != windows.TRUE)
            return windows.unexpectedError(windows.kernel32.GetLastError());
    }

    pub const Event = packed struct {
        inner: OVERLAPPED_ENTRY,

        pub fn getData(self: @This(), poller: *EventPoller) usize {
            return @ptrToInt(self.inner.lpCompletionKey);
        }

        pub fn getResult(self: @This()) zio.Result {
            const overlapped = self.inner.lpOverlapped orelse return zio.Result {
                .data = 0,
                .status = .Completed, // notify() result
            };
            return zio.Result {
                .data = self.inner.dwNumberOfBytesTransferred,
                .status = if (@ptrToInt(overlapped.Internal) == STATUS_COMPLETED) .Completed else .Error,
            };
        }

        pub fn getIdentifier(self: @This()) usize {
            const identifier = @ptrToInt(self.inner.lpOverlapped);
            const alignment = std.math.max(zio.EventPoller.READ, zio.EventPoller.WRITE);
            std.debug.assert(std.mem.isAligned(identifier, alignment));
            return identifier;
        }
    };

    pub fn poll(self: *@This(), events: []zio.EventPoller.Event, timeout: ?u32) zio.EventPoller.PollError![]Event {
        var events_found: windows.ULONG = 0;
        const result = GetQueuedCompletionStatusEx(
            self.iocp,
            @ptrCast([*]OVERLAPPED_ENTRY, events.ptr),
            @intCast(windows.ULONG, clamp(windows.ULONG, events.len)),
            &events_found,
            if (timeout) |t| @intCast(windows.DWORD, t) else windows.INFINITE,
            windows.FALSE
        );

        if (self.iocp == windows.INVALID_HANDLE_VALUE)
            return zio.EventPoller.PollError.InvalidHandle;
        if (result == windows.TRUE or timeout == null)
            return events[0..events_found];
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
};

pub const Socket = struct {
    handle: Handle,
    is_overlapped: bool,
    recv_flags: windows.DWORD,
    reader: windows.OVERLAPPED,
    writer: windows.OVERLAPPED,

    pub fn getHandle(self: @This()) Handle {
        return self.handle;
    }

    pub fn fromHandle(handle: Handle, flags: u32) @This() {
        var self: @This() = undefined;
        self.is_overlapped = (flags & zio.Socket.Nonblock) != 0;
        self.handle = handle;
        return self;
    }

    pub fn init(self: *@This(), flags: u32) zio.Socket.Error!void {
        const dwFlags = if ((flags & zio.Socket.Nonblock) != 0) WSA_FLAG_OVERLAPPED else 0;
        const family = switch (flags & (zio.Socket.Ipv4 | zio.Socket.Ipv6)) {
            zio.Socket.Ipv4 => AF_INET,
            zio.Socket.Ipv6 => AF_INET6,
            else => AF_UNSPEC,
        };
        const protocol = switch (flags & (zio.Socket.Tcp | zio.Socket.Udp | zio.Socket.Raw)) {
            zio.Socket.Raw => 0,
            zio.Socket.Udp => IPPROTO_UDP,
            zio.Socket.Tcp => IPPROTO_TCP,
            else => return zio.SOcket.Error.InvalidValue,
        };
        const sock_type = switch (flags & (zio.Socket.Tcp | zio.Socket.Udp | zio.Socket.Raw)) {
            zio.Socket.Raw => SOCK_RAW,
            zio.Socket.Udp => SOCK_DGRAM,
            zio.Socket.Tcp => SOCK_STREAM,
            else => return zio.Socket.Error.InvalidValue,
        };

        self.is_overlapped = dwFlags != 0;
        self.handle = WSASocketA(family, protocol, sock_type, null, 0, dwFlags);
        if (self.handle == windows.INVALID_HANDLE_VALUE)
            return zio.Socket.Error.InvalidHandle;
    }
    
    pub fn close(self: *@This()) void {
        _ = closesocket(self.handle);
        self.handle = windows.INVALID_HANDLE_VALUE;
    }

    pub fn isReadable(self: *@This(), identifier: usize) bool {
        return @ptrToInt(&self.reader) == identifier;
    }

    pub fn isWriteable(self: *@This(), identifier: usize) bool {
        return @ptrToInt(&self.writer) == identifier;
    }

    pub fn setOption(option: Option) zio.Socket.OptionError!void {
        // TODO
    }

    pub fn getOption(option: *Option) zio.Socket.OptionError!void {
        // TODO
    }

    pub const Ipv4 = packed struct {
        inner: SOCKADDR_IN,

        pub fn from(address: u32, port: u16) @This() {
            return @This() {
                .inner = SOCKADDR_IN {
                    .sin_family = AF_INET,
                    .sin_addr = IN_ADDR { .s_addr = address },
                    .sin_port = std.mem.nativeToBig(u16, port),
                    .sin_zero = [_]u8{0} ** @sizeOf(@typeOf(SOCKADDR_IN(undefined).sin_zero)),
                }
            };
        }
    };

    pub const Ipv6 = packed struct {
        inner: SOCKADDR_IN6,

        pub fn from(address: u128, port: u16) @This() {
            return @This() {
                .inner = SOCKADDR_IN6 {
                    .sin6_flowinfo = 0,
                    .sin6_scope_id = 0,
                    .sin6_family = AF_INET6,
                    .sin6_port = std.mem.nativeToBig(u16, port),
                    .sin6_addr = IN6_ADDR { .Word = @bitCast(@typeOf(IN6_ADDR(undefined).Word), address) },
                }
            };
        }
    };

    pub fn read(self: *@This(), buffers: []zio.Buffer) zio.Result {
        return self.performIO(&self.reader, null, buffers);
    }

    pub fn readFrom(self: *@This(), address: *zio.Socket.Address, buffers: []zio.Buffer) zio.Result {
        return self.performIO(&self.reader, address, buffers);
    }

    pub fn write(self: *@This(), buffers: []const zio.Buffer) zio.Result {
        return self.performIO(&self.writer, null, buffers);
    }

    pub fn writeFrom(self: *@This(), address: *const zio.Socket.Address, buffers: []const zio.Buffer) zio.Result {
        return self.performIO(&self.writer, address, buffers);
    }

    inline fn performIO(
        self: *@This(),
        overlapped: *windows.OVERLAPPED,
        address: ?*const zio.Socket.Address,
        buffers: []const zio.Buffer
    ) zio.Result {
        if (self.is_overlapped)
            @memset(@ptrCast([*]u8, overlapped), 0, @sizeOf(windows.OVERLAPPED));
        
        const ptr = if (self.is_overlapped) overlapped else null;
        const buf_ptr = @intToPtr([*]WSABUF, @ptrToInt(buffers.ptr));
        const buf_len = @intCast(windows.DWORD, clamp(windows.DWORD, buffers.len));
        const addr_ptr = @intToPtr(?*SOCKADDR, @ptrToInt(if (address) |addr| &addr.address else null));

        var result: c_int = undefined;
        switch (overlapped) {
            &self.writer => {
                const addr_len = if (address) |addr| addr.length else 0; 
                result = WSASendTo(self.handle, buf_ptr, buf_len, null, 0, addr_ptr, addr_len, ptr, null);
            },
            &self.reader => {
                self.recv_flags = 0;
                const addr_len = if (address) |addr| &addr.length else null; 
                result = WSARecvFrom(self.handle, buf_ptr, buf_len, null, &self.recv_flags, addr_ptr, addr_len, ptr, null);
            },
            else => unreachable,
        }

        return zio.Result {
            .data = @ptrToInt(self.reader.InternalHigh),
            .status = 
                if (result == 0) .Completed
                else if (WSAGetLastError() == WSA_IO_PENDING) .Retry
                else .Error,
        };
    }

    pub fn bind(self: *@This(), address: *zio.Socket.Address) zio.Socket.BindError!void {
        // TODO
    }

    pub fn listen(self: *@This(), backlog: u16) zio.Socket.ListenError!void {
        // TODO
    }

    pub fn accept(self: *@This(), address: *zio.Socket.Address) zio.Result {
        // TODO
    }

    pub fn connect(self: *@This(), address: *zio.Socket.Address) zio.Result {
        // TODO
    }
};

fn clamp(comptime Int: type, number: var) @typeOf(number) {
    const max_value = @intCast(@typeOf(number), std.math.maxInt(Int));
    return std.math.min(max_value, number);
}

///-----------------------------------------------------------------------------///
///                                API Definitions                              ///
///-----------------------------------------------------------------------------///

const AF_UNSPEC: windows.DWORD = 0;
const AF_INET: windows.DWORD = 2;
const AF_INET6: windows.DWORD = 6;
const SOCK_STREAM: windows.DWORD = 1;
const SOCK_DGRAM: windows.DWORD = 2;
const SOCK_RAW: windows.DWORD = 3;
const IPPROTO_TCP: windows.DWORD = 6;
const IPPROTO_UDP: windows.DWORD = 17;

const STATUS_COMPLETED = 0;
const WSAEMSGSIZE: windows.DWORD = 10040;
const WSA_IO_PENDING: windows.DWORD = 997;
const WSA_INVALID_HANDLE: windows.DWORD = 6;
const WSA_FLAG_OVERLAPPED: windows.DWORD = 0x01;

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

const OverlappedCompletionRoutine = fn(
    dwErrorCode: windows.DWORD,
    dwNumberOfBytesTransferred: windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) void;

var ConnectEx: fn(
    s: windows.HANDLE,
    name: *const sockaddr,
    name_len: c_int,
    lpSendBuffer: windows.PVOID,
    dwSendDataLength: windows.DWORD,
    lpdwBytesSent: *windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) windows.BOOL = undefined;

var AcceptEx: fn(
    sListenSocket: windows.HANDLE,
    sAcceptSocket: windows.HANDLE,
    lpOutputBuffer: ?windows.PVOID,
    dwReceiveDataLength: windows.DWORD,
    dwLocalAddressLength: windows.DWORD,
    dwRemoteAddressLength: windows.DWORD,
    lpdwBytesReceived: *windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) windows.BOOL = undefined;

const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: system.ULONG_PTR,
    lpOverlapped: ?*system.OVERLAPPED,
    Internal: system.ULONG_PTR,
    dwNumberOfBytesTransferred: system.DWORD,
};

extern "kernel32" stdcallcc fn GetQueuedCompletionStatusEx(
    CompletionPort: system.HANDLE,
    lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
    ulCount: system.ULONG,
    ulNumEntriesRemoved: system.PULONG,
    dwMilliseconds: system.DWORD,
    fAlertable: system.BOOL,
) system.BOOL;

extern "ws2_32" stdcallcc fn closesocket(s: windows.HANDLE) c_int;
extern "ws2_32" stdcallcc fn listen(
    s: windows.HANDLE,
    backlog: c_int,
) c_int;
extern "ws2_32" stdcallcc fn bind(
    s: windows.HANDLE,
    addr: *const SOCKADDR,
    addr_len: c_int,
) c_int;

extern "Ws2_32" stdcallcc fn WSAGetLastError() c_int;
extern "ws2_32" stdcallcc fn WSACleanup() c_int;
extern "ws2_32" stdcallcc fn WSAStartup(
    wVersionRequested: windows.WORD,
    lpWSAData: *WSAData,
) c_int;

extern "ws2_32" stdcallcc fn WSAIoctl(
    s: windows.HANDLE,
    dwIoControlMode: windows.DWORD,
    lpvInBuffer: windows.PVOID,
    cbInBuffer: windows.DWORD,
    lpvOutBuffer: windows.PVOID,
    cbOutBuffer: windows.DWORD,
    lpcbBytesReturned: *windows.DWORD,
    lpOverlapped: ?*windows.OVERLAPPED,
    lpCompletionRoutine: ?fn(*windows.OVERLAPPED) usize,
) c_int;

extern "ws2_32" stdcallcc fn WSASocketA(
    family: windows.DWORD,
    sock_type: windows.DWORD,
    protocol: windows.DWORD,
    lpProtocolInfo: usize,,
    group: usize,
    dwFlags: windows.DWORD,
) windows.HANDLE;

extern "ws2_32" stdcallcc fn WSASendTo(
    s: windows.HANDLE,
    lpBuffers: [*]WSABUF,
    dwBufferCount: windows.DWORD,
    lpNumberOfBytesSent: ?*windows.DWORD,
    dwFlags: windows.DWORD,
    lpTo: ?*const SOCKADDR,
    iToLen: c_int,
    lpOverlapped: ?*windows.OVERLAPPED,
    lpCompletionRouting: ?OverlappedCompletionRoutine,
) c_int;

extern "ws2_32" stdcallcc fn WSARecvFrom(
    s: windows.HANDLE,
    lpBuffers: [*]WSABUF,
    dwBufferCount: windows.DWORD,
    lpNumberOfBytesRecv: ?*windows.DWORD,
    lpFlags: *windows.DWORD,
    lpFrom: ?*SOCKADDR,
    lpFromLen: *c_int,
    lpOverlapped: ?*windows.OVERLAPPED,
    lpCompletionRouting: ?OverlappedCompletionRoutine,
) c_int;