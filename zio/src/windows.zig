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
        pub fn findFunction(sock: Handle, id: GUID, function: var) zio.InitError!void {
            var guid: GUID = id;
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
        _ = windows.kernel32.CreateIoCompletionPort(handle, self.iocp, key, 0)
            orelse return // TODO
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

        pub fn getData(self: @This()) usize {
            return @ptrToInt(self.inner.lpCompletionKey);
        }

        pub fn getResult(self: @This()) zio.Result {
            const overlapped = self.inner.lpOverlapped orelse return zio.Result {
                .transferred = 0,
                .status = .Completed,
            };
            return zio.Result {
                .transferred = self.inner.dwNumberOfBytesTransferred,
                .status = if (overlapped.Internal == STATUS_COMPLETED) .Completed else .Error,
            };
        }

        pub fn getIdentifier(self: @This()) usize {
            const identifier = @ptrToInt(self.inner.lpOverlapped);
            const alignment = std.math.max(zio.EventPoller.READ, zio.EventPoller.WRITE);
            std.debug.assert(std.mem.isAligned(identifier, alignment));
            return identifier;
        }
    };

    pub fn poll(self: *@This(), events: []Event, timeout: ?u32) zio.EventPoller.PollError![]Event {
        var events_found: windows.ULONG = 0;
        const result = GetQueuedCompletionStatusEx(
            self.iocp,
            events.ptr,
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
    reader: windows.OVERLAPPED,
    writer: windows.OVERLAPPED,

    pub fn getHandle(self: @This()) Handle {
        return self.handle;
    }

    pub fn fromHandle(handle: Handle) @This() {
        var self: @This() = undefined;
        self.handle = handle;
        return self;
    }

    pub fn init(self: *@This(), flags: u32) zio.Socket.Error!void {
        // TODO
    }
    
    pub fn close(self: *@This()) void {
        // TODO
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

    pub fn read(self: *@This(), buffers: []zio.Buffer) zio.Result {
        // TODO
    }

    pub fn write(self: *@This(), buffers: []const zio.Buffer) zio.Result {
        // TODO
    }

    pub const Ipv4 = packed struct {

        pub fn from(address: u32, port: u16) @This() {
            // TODO
        }
    };

    pub const Ipv6 = packed struct {

        pub fn from(address: u128, port: u16) @This() {
            // TODO
        }
    };

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
