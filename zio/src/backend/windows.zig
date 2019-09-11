const std = @import("std");
const windows = std.os.windows;
const zio = @import("../../zio.zig");

pub fn initialize() zio.InitError!void {
    const wsa_version = windows.WORD(0x0202);
    var wsa_data: WSAData = undefined;
    if (WSAStartup(wsa_version, &wsa_data) != 0)
        return zio.InitError.InvalidState;
    if (wsa_data.wVersion != wsa_version)
        return zio.InitError.InvalidState;

    const dummy_socket = 
}

pub fn cleanup() void {
    _ = WSACleanup();    
}

pub const Handle = windows.HANDLE;

pub const Buffer = struct {
    inner: ,

    pub fn fromBytes(bytes: []const u8) @This() {
        return @This() {
            .inner = 
        };
    }

    pub fn getBytes(self: @This()) []u8 {
        
    }
};

pub const IncomingPadding = ;

pub const Ipv4 = packed struct {
    inner: ,

    pub fn from(address: u32, port: u16) @This() {
        return @This() {
            .inner = 
        };
    }
};

pub const Ipv6 = packed struct {
    inner: ,

    pub fn from(address: u128, port: u16, flow: u32, scope: u32) @This() {
        return @This() {
            .inner = 
        };
    }
};

pub const Event = struct {
    inner: ,

    pub fn getData(self: *@This(), poller: *Poller) usize {
        
    }

    pub fn getResult(self: *@This()) zio.Result {
        
    }

    pub const Poller = struct {
        pub fn init(self: *@This()) zio.Event.Poller.InitError!void {
            
        }

        pub fn close(self: *@This()) void {
            
        }

        pub fn getHandle(self: @This()) zio.Handle {
            
        }

        pub fn fromHandle(handle: zio.Handle) @This() {
            
        }

        pub fn register(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            
        }

        pub fn reregister(self: *@This(), handle: zio.Handle, flags: u8, data: usize) zio.Event.Poller.RegisterError!void {
            
        }

        pub fn send(self: *@This(), data: usize) zio.Event.Poller.SendError!void {
            
        }

        pub fn poll(self: *@This(), events: []Event, timeout: ?u32) zio.Event.Poller.PollError![]Event {
            
        }
    };
};

pub const Socket = struct {

    pub fn init(self: *@This(), flags: u8) zio.Socket.InitError!void {
        
    }

    pub fn close(self: *@This()) void {
        
    }

    pub fn getHandle(self: @This()) zio.Handle {
        
    }

    pub fn fromHandle(handle: zio.Handle) @This() {
        
    }

    pub fn isReadable(self: *const @This(), event: Event) bool {
        
    }

    pub fn isWriteable(self: *const @This(), event: Event) bool {
        
    }

    pub fn setOption(option: Option) zio.Socket.OptionError!void {
       
    }

    pub fn getOption(option: *Option) zio.Socket.OptionError!void {
        
    }

    pub fn bind(self: *@This(), address: *const zio.Address) zio.Socket.BindError!void {
        
    }

    pub fn listen(self: *@This(), backlog: u16) zio.Socket.ListenError!void {
        
    }

    pub fn connect(self: *@This(), address: *const zio.Address) zio.Result {
        
    }

    pub fn accept(self: *@This(), incoming: *zio.Address.Incoming) zio.Result {
        
    }

    pub fn recv(self: *@This(), address: ?*zio.Address, buffers: []zio.Buffer) zio.Result {
        
    }

    pub fn send(self: *@This(), address: ?*const zio.Address, buffers: []const zio.Buffer) zio.Result {
        
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
const IPPROTO_TCP: windows.DWORD = 6;
const IPPROTO_UDP: windows.DWORD = 17;

const STATUS_COMPLETED = 0;
const WSA_IO_PENDING: windows.DWORD = 997;
const WSA_INVALID_HANDLE: windows.DWORD = 6;
const WSA_FLAG_OVERLAPPED: windows.DWORD = 0x01;
const WSAEMSGSIZE: windows.DWORD = 10040;
const WSANOTINITIALIZED: windows.DWORD = 10093;
const WSAEADDRINUSE: windows.DWORD = 10048;
const WSAEADDRNOTAVAIL: windows.DWORD = 10049;
const WSAEINPROGRESS: windows.DWORD = 10036;
const WSAEMFILE: windows.DWORD = 10024;
const WSAEISCONN: windows.DWORD = 10056;
const WSAENETDOWN: windows.DWORD = 10050;
const WSAEINVAL: windows.DWORD = 10022;
const WSAEFAULT: windows.DWORD = 10014;
const WSAEPROTOTYPE: windows.DWORD = 10041;
const WSAENOBUFS: windows.DWORD = 10055;
const WSAENOTSOCK: windows.DWORD = 10038;
const WSAEOPNOTSUPP: windows.DWORD = 10045;
const WSAEAFNOTSUPPORT: windows.DWORD = 10047;
const WSAEPROTONOSUPPORT: windows.DWORD = 10043;
const WSAESOCKTNOSUPPORT: windows.DWORD = 10044;
const WSAEINVALIDPROVIDER: windows.DWORD = 10105;
const WSAEINVALIDPROCTABLE: windows.DWORD = 10104;
const WSAEPROVIDERFAILEDINIT: windows.DWORD = 10106;

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
    socket: SOCKET,
    name: *const sockaddr,
    name_len: c_int,
    lpSendBuffer: windows.PVOID,
    dwSendDataLength: windows.DWORD,
    lpdwBytesSent: *windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) windows.BOOL = undefined;

var AcceptEx: fn(
    sListenSocket: SOCKET,
    sAcceptSocket: SOCKET,
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

const Mswsock = {
    pub extern "ws2_32" stdcallcc fn closesocket(socket: SOCKET) c_int;
    pub extern "ws2_32" stdcallcc fn listen(
        socket: SOCKET,
        backlog: c_int,
    ) c_int;
    pub extern "ws2_32" stdcallcc fn bind(
        socket: SOCKET,
        addr: *const SOCKADDR,
        addr_len: c_int,
    ) c_int;
};

extern "Ws2_32" stdcallcc fn WSAGetLastError() c_int;
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
    socket: SOCKET,
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
    socket: SOCKET,
    lpBuffers: [*]WSABUF,
    dwBufferCount: windows.DWORD,
    lpNumberOfBytesRecv: ?*windows.DWORD,
    lpFlags: *windows.DWORD,
    lpFrom: ?*SOCKADDR,
    lpFromLen: *c_int,
    lpOverlapped: ?*windows.OVERLAPPED,
    lpCompletionRouting: ?OverlappedCompletionRoutine,
) c_int;