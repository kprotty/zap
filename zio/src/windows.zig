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
        const limit = @intCast(usize, std.math.max(windows.DWORD));
        return @This() {
            .inner = WSABUF {
                .buf = bytes.ptr,
                .len = @intCast(windows.DWORD, std.math.min(limit, bytes.len)),
            }
        };
    }

    pub fn getBytes(self: @This()) []u8 {
       return self.inner.buf[0..self.inner.len];
    }
};

pub const EventPoller = struct {

    pub fn getHandle(self: @This()) Handle {
        // TODO
    }

    pub fn fromHandle(handle: Handle) @This() {
        // TODO
    }

    pub fn init(self: *@This()) zio.EventPoller.Error!void {
        // TODO
    }

    pub fn close(self: *@This()) void {
        // TODO
    }

    pub fn register(self: *@This(), handle: Handle, flags: u32, data: usize) RegisterError!void {
        // TODO
    }

    pub fn reregister(self: *@This(), handle: Handle, flags: u32, data: usize) RegisterError!void {
        // TODO
    }

    pub fn notify(self: *@This(), data: usize) NotifyError!void {
        // TODO
    }

    pub const Event = packed struct {

        pub fn getData(self: @This()) usize {
            // TODO
        }

        pub fn getResult(self: @This()) Result {
            // TODO
        }

        pub fn isReadable(self: @This()) bool {
            // TODO
        }

        pub fn isWriteable(self: @This()) bool {
            // TODO
        }
    };

    pub fn poll(self: *@This(), events: []Event, timeout: ?u32) PollError![]Event {
        // TODO   
    }
};

pub const Socket = struct {

    pub fn getHandle(self: @This()) Handle {
        // TODO
    }

    pub fn fromHandle(handle: Handle) @This() {
        // TODO
    }

    pub fn init(self: *@This(), flags: u32) zio.Socket.Error!void {
        // TODO
    }
    
    pub fn close(self: *@This()) void {
        // TODO
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
