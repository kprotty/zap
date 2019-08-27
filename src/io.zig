const std = @import("std");
const system = std.os.system;
const builtin = @import("builtin");

pub const backend = switch (builtin.os) {
    .linux => Linux,
    .windows => Windows,
    else => Posix,
};

const Linux = struct {
    pub const Handle = i32;

    pub const Buffer = extern struct {
        inner: system.iovec,

        pub fn from(buffer: []const u8) ?@This() {
            // arbitrary limit to return optional like Windows, 
            /// but you probably shouldnt be doing io on terrabytes anyway ;-)
            if (buffer.len == std.math.maxInt(usize))
                return null;
            const iovec = system.iovec { .iov_base = buffer.ptr, .iov_len = buffer.len };
            return @This() { .inner = iovec };
        }

        pub fn to(self: @This()) []u8 {
            return self.inner.iov_base[0..self.inner.iov_len];
        }
    };

    pub const RequestToken = extern struct {
        // need something here as its zeroed on start of IO operation
        inner: u1,

        // returns null to signify that the action should be retried to obtain the result since readiness based
        pub fn getResult(self: @This()) ?usize {
            return null;
        }
    };

    const Selector = struct {
        epoll_fd: Handle,
        event_fd: Handle,

        pub fn init(self: *@This()) !void {
            self.event_fd = try system.eventfd(0, system.EFD_NONBLOCK);
            self.epoll_fd = try system.epoll_create1(system.EPOLL_CLOEXEC);
            try self.register(self.event_fd, self);
        }

        pub fn deinit(self: *@This()) void {
            system.close(self.event_fd);
            system.close(self.epoll_fd);
        }

        pub fn register(self: *@This(), handle: Handle, token: usize) !void {
            const writeable = if (token == @ptrToInt(self)) 0 else system.EPOLLOUT;
            var event = system.epoll_event {
                .data = system.epoll_data { .ptr = token },
                .events = system.EPOLLRDHUP | system.EPOLLET | system.EPOLLIN | writeable,
            };
            try system.epoll_ctl(self.epoll_fd, system.EPOLL_CTL_ADD, handle, &event);
        }

        pub fn notify(self: *@This(), token: usize) !void {
            var signal = @intCast(u64, token); // event fd only allows 64bit packets on all platforms
            try system.write(self.event_fd, @ptrCast([*]u8, &signal)[0..@sizeOf(@typeOf(signal))]);
        }

        pub fn poll(self: *@This(), events: []Event, timeout_ms: ?u32) ![]Event {
            // that in the system of the stdlib doesnt return error so have to do it manually
            const num_events = @intCast(i32, events.len);
            const timeout = @bitCast(i32, timeout_ms orelse -1);
            while (true) {
                const result = system.epoll_wait(self.epoll_fd, events.ptr, num_events, timeout);
                switch (system.errno(result)) {
                    0 => return events[0..@intCast(usize, result)],
                    system.EINVAL => return error.InvalidEpollDescriptor,
                    system.EBADF => return error.InvalidFileDescriptor,
                    system.EFAULT => return error.InvalidEventMemory,
                    system.EINTR => continue,
                    else => unreachable
                }
            }
        }

        pub const Event = packed struct {
            inner: system.epoll_event,
            
            pub fn getToken(self: @This()) usize {
                return self.inner.data.ptr;
            }

            pub fn isReadable(self: @This()) bool {
                return (self.inner.events & system.EPOLLIN) != 0;
            }

            pub fn isWriteable(self: @This()) bool {
                return (self.inner.events & system.EPOLLOUT) != 0;
            }

            pub fn isError(self: @This()) bool {
                return (self.inner.events & (system.EPOLLERR | system.EPOLLHUP | system.EPOLLRDHUP)) != 0;
            }
        };
    };
};

const Windows = {
    pub const Handle = system.HANDLE;

    pub const Buffer = extern struct {
        inner: WSABUF,

        pub const WSABUF = extern struct {
            len: system.ULONG,
            buf: [*]u8,
        };

        pub fn from(buffer: []const u8) ?@This() {
            if (buffer.len > usize(std.math.maxInt(system.DWORD)))
                return null;
            const wsa_buf = WSABUF { .buf = buffer.ptr, .len = @truncate(system.DWORD, buffer.len) };
            return @This() { .inner = wsa_buf };
        }

        pub fn to(self: @This()) []u8 {
            return self.inner.buf[0..self.inner.len];
        }
    };

    pub const RequestToken = extern struct {
        inner: system.OVERLAPPED,

        // should return the dwNumberOfBytesTransferred from the event
        pub fn getResult(self: @This()) ?usize {
            return @ptrToInt(self.inner.InternalHigh orelse return null);
        }
    };

    pub const Selector = struct {
        iocp: Handle,

        pub fn init(self: *@This()) !void {
            // handle WSA initiailization in the selector
            try Socket.wsaInit();
            self.iocp = try system.CreateIoCompletionPort(system.INVALID_HANDLE_VALUE, null, undefined, 1);
        }

        pub fn deinit(self: *@This()) void {
            system.CloseHandle(self.iocp);
            Socket.wsaDeinit(); 
        }

        pub fn register(self: *@This(), handle: Handle, token: usize) !void {
            _ = try system.CreateIoCompletionPort(handle, self.iocp, @intToPtr(system.ULONG_PTR, token), 1);
        }

        pub fn notify(self: *@This(), token: usize) !void {
            try system.PostQueueCompletionStatus(self.iocp, undefined, @ptrCast(system.ULONG_PTR, self), null);
        }

        pub fn poll(self: *@This(), events: []Event, timeout_ms: ?u32) ![]Event {
            var num_events_found: system.ULONG = undefined;
            return switch (GetQueuedCompletionStatusEx(
                self.iocp,
                events.ptr,
                @intCast(system.ULONG, events.len),
                &num_events_found,
                timeout_ms orelse system.INFINITE,
                system.FALSE,
            )) {
                // events were found. Store the bytes transferred in InternalHigh since the kernel wont be touching that soon
                system.TRUE => found_events: {
                    const new_events = events[0..num_events_found];
                    for (new_events) |*event|
                        event.lpOverlapped.InternalHigh = @intCast(system.ULONG_PTR, event.dwNumberOfBytesTransferred);
                    break :found_events new_events;
                },
                // unknown error since it doesnt really say what to handle in the docs ;/
                else => system.unexpectedError(system.kernel32.GetLastError()),
            };
        }

        pub const Event = extern struct {
            // store the Readable/Writable propery in OVERLAPPED.hEvent and hope the kernel doesnt touch it
            inner: OVERLAPPED_ENTRY,
            
            pub fn getToken(self: @This()) usize {
                return @ptrToInt(self.inner.lpCompletionKey);
            }

            pub fn isReadable(self: @This()) bool {
                return @ptrToInt((self.inner.lpOverlapped orelse return false).hEvent) == 0;
            }

            pub fn isWriteable(self: @This()) bool {
                return @ptrToInt((self.inner.lpOverlapped orelse return false).hEvent) != 0;
            }

            pub fn isError(self: @This()) bool {
                return (self.inner.lpOverlapped orelse return false).Internal != 0;
            }
        };

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
    };

    pub const Socket = struct {
        pub fn wsaInit() !void {
            // initialize Winsock 2.2
            var wsa_data: WSAData = undefined;
            const wsa_version = system.WORD(0x0202);
            if (WSAStartup(wsa_version, &wsa_data) != 0)
                return error.WSAStartupFailed;
            errdefer { _ = WSACleanup(); }
            if (wsa_data.wVersion != wsa_version)
                return error.WSAInvalidVersion;

            // Fetch the AcceptEx and ConnectEx functions since theyre dynamically discovered
            // The dummy socket is needed for WSAIoctl to fetch the addresses
            const dummy = socket(AF_INET, SOCK_STREAM, 0);
            if (dummy == system.INVALID_HANDLE_VALUE)
                return error.InvalidIoctlSocket;
            defer closesocket(dummy);
            var dwBytes: system.DWORD = undefined;
            
            // find ConnectEx
            var guid = WSAID_CONNECTEX;
            if (WSAIoctl(
                dummy,
                SIO_GET_EXTENSION_FUNCTION_POINTER,
                &guid,
                @sizeOf(@typeOf(guid)),
                &ConnectEx,
                @sizeOf(@typeOf(ConnectEx)),
                &dwBytes,
                null,
                null,
            ) != 0)
                return error.WSAIoctlConnectEx;

            // find AcceptEx
            gui = WSAID_ACCEPTEX;
            if (WSAIoctl(
                dummy,
                SIO_GET_EXTENSION_FUNCTION_POINTER,
                &guid,
                @sizeOf(@typeOf(guid)),
                &AcceptEx,
                @sizeOf(@typeOf(AcceptEx)),
                &dwBytes,
                null,
                null,
            ) != 0)
                return error.WSAIoctlAcceptEx;
        }

        pub fn wsaDeinit() void {

        }

        const WSABUF = extern struct {

        };

        const WSAData = extern struct {

        };

        var ConnectEx: fn(
            s: system.HANDLE,
            name: *const sockaddr,
            name_len: c_int,
            lpSendBuffer: system.PVOID,
            dwSendDataLength: system.DWORD,
            lpdwBytesSent: *system.DWORD,
            lpOverlapped: *system.OVERLAPPED,
        ) system.BOOL = undefined;

        var AcceptEx: fn(
            sListenSocket: system.HANDLE,
            sAcceptSocket: system.HANDLE,
            lpOutputBuffer: ?system.PVOID,
            dwReceiveDataLength: system.DWORD,
            dwLocalAddressLength: system.DWORD,
            dwRemoteAddressLength: system.DWORD,
            lpdwBytesReceived: *system.DWORD,
            lpOverlapped: *system.OVERLAPPED,
        ) system.BOOL = undefined;

        extern "ws2_32" stdcallcc fn WSACleanup() c_int;
        extern "ws2_32" stdcallcc fn WSAStartup(
            wVersionRequested: system.WORD,
            lpWSAData: *WSAData,
        ) c_int;

        extern "ws2_32" stdcallcc fn WSAIoctl(
            s: system.HANDLE,
            dwIoControlMode: system.DWORD,
            lpvInBuffer: system.PVOID,
            cbInBuffer: system.DWORD,
            lpvOutBuffer: system.PVOID,
            cbOutBuffer: system.DWORD,
            lpcbBytesReturned: *system.DWORD,
            lpOverlapped: ?*system.OVERLAPPED,
            lpCompletionRoutine: ?fn(*system.OVERLAPPED) usize
        ) c_int;
    };
};
