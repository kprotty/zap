pub const BOOL = c_int;
pub const WORD = u16;
pub const DWORD = u32;
pub const ULONG = u32;
pub const HANDLE = *c_void;
pub const SOCKET = HANDLE;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub const INFINITE: DWORD = ~DWORD(0);
pub const INVALID_HANDLE: HANDLE = @intToPtr(HANDLE, ~usize(0))

pub const WSA_IO_PENDING: c_int = 997;

pub const WSAOVERLAPPED_COMPLETION_ROUNTINE = extern fn(
    dwErrorCode: DWORD,
    dwNumberOfBytesTransferred: DWORD,
    lpOverlapped: *OVERLAPPED,
) void;

pub const WSABUF = extern struct {
    len: ULONG,
    buf: [*]const u8,
};

pub const OVERLAPPED = extern struct {
    Internal: ?*ULONG,
    InternalHigh: ?*ULONG,
    Offset: DWORD,
    OffsetHigh: DWORD,
    hEvent: HANDLE,
};

pub const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: ?*ULONG,
    lpOverlapped: *OVERLAPPED,
    Internal: *ULONG,
    dwNumberOfBytesTransferred: DWORD,
};

pub extern "kernel32" stdcallcc fn CloseHandle(
    hObject: HANDLE,
) BOOL;

pub extern "kernel32" stdcallcc fn CreateIoCompletionPort(
    FileHandle: HANDLE,
    ExistingCompletionPort: ?HANDLE,
    CompletionKey: ?*ULONG,
    NumberOfConcurrentThreads: DWORD,
) ?HANDLE;

pub extern "kernel32" stdcallcc fn GetQueuedCompletionStatusEx(
    CompletionPort: HANDLE,
    lpCompetionPortEntries: [*]OVERLAPPED_ENTRY,
    ulCount: ULONG,
    ulNumEntriesRemoved: *ULONG,
    dwMilliseconds: DWORD,
    fAlertable: BOOL,
) BOOL;

pub const WSADATA = extern struct {
    wVersion: WORD,
    wHighVersion: WORD,
    iMaxSockets: c_ushort,
    iMaxUdpDg: c_ushort,
    lpVendorInfo: [*]const u8,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
};

pub extern "ws2_32" stdcallcc WSAGetLastError() c_int;

pub extern "ws2_32" stdcallcc fn WSACleanup() c_int;
pub extern "ws2_32" stdcallcc fn WSAStartup(
    wVersionRequired: WORD,
    lpWSAData: *WSADATA,
) c_int;

pub extern "ws2_32" stdcallcc fn WSASend(
    socket: HANDLE,
    lpBuffers: [*]WSABUF,
    dwBufferCount: DWORD,
    lpNumberOfBytesSent: *DWORD,
    dwFlags: DWORD,
    lpOverlapped: *OVERLAPPED,
    lpCompletionRoutine: ?WSAOVERLAPPED_COMPLETION_ROUNTINE,
) c_int;

pub extern "ws2_32" stdcallcc fn WSASend(
    socket: HANDLE,
    lpBuffers: [*]WSABUF,
    dwBufferCount: DWORD,
    lpNumberOfBytesSent: *DWORD,
    lpdwFlags: *DWORD,
    lpOverlapped: *OVERLAPPED,
    lpCompletionRoutine: ?WSAOVERLAPPED_COMPLETION_ROUNTINE,
) c_int;
