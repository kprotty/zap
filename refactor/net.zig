const std = @import("std");
const builtin = @import("builtin");
const Task = @import("sched.zig").Node.Task;

const os = std.os;
const system = os.system;

pub const Backend = switch (builtin.os) {
    .windows => WinSock,
    else => PosixSocket,
};

pub const Socket = struct {
    
};

const IoStream = struct {
    pub const Readable   = u2(0b01);
    pub const Writeable  = u2(0b10);
    pub const Disposable = u2(0b00);

    reader: Event,
    writer: Event,

    pub fn init(self: *@This()) void {
        self.reader.init();
        self.writer.init();
    }

    pub fn signal(self: *@This(), flags: u2, data: u32) ?*Task {
        var reader_task: ?*Task = null;
        var writer_task: ?*Task = null;

        if (flags == Disposable) {
            writer_task = self.writer.signal(Event.Close);
            reader_task = self.reader.signal(Event.Close)
        } else {
            if ((flags & Writeable) != 0)
                writer_task = self.writer.signal(Event.EncodeReady(data));
            if ((flags & Readable) != 0)
                reader_task = self.reader.signal(Event.EncodeReady(data));  
        }

        // return any tasks found. Try and link them together if theres multiple.
        if (writer_task) |task|
            task.link = reader_task;
        return writer_task orelse reader_task;
    }

    const Event = struct {
        /// Thread safe mechanism for event notification and task wakeup.
        /// `state` begins as "Empty" and event pollers signal by setting it to either "Close" or "Ready".
        /// Under "Ready", the upper bits are used as a hint to the IO waiting for event for how many bytes to use.
        /// The upper bits are set only on kevent as they cant be used to know exactly how many bytes to read as an optimization.
        /// If an IO operation fails to consume a "Close" or "Ready" event, it then starts to suspend.
        /// Once suspended, it tries and to consume the event once more just in case it was set during the process.
        /// If that fails as well, the `state` is set to "Waiting" indicating that the upper bits represent a `Task` pointer.
        /// NOTE: The reason these tag states are 2-bits large is that maximum value we can fit into a 32bit or 64bit aligned pointer. 
        pub const Empty   = usize(0b11);
        pub const Close   = usize(0b10);
        pub const Ready   = usize(0b01);
        pub const Waiting = usize(0b00);
        state: usize,

        pub fn init(self: *@This()) void {
            self.state = Empty;
        }

        pub inline fn EncodeReady(data: u32) usize {
            return (@intCast(usize, data) << 2) | Ready;
        }

        pub inline fn DecodeReady(data: usize) u32 {
            return @truncate(u32, data >> 2);
        }

        pub fn signal(self: *@This(), data: usize) ?*Task {
            // PRODUCER: update the state & return a Task if there was any waiting 
            @fence(.Release);
            const state = @atomicRmw(usize, &self.state, .Xchg, data, .Monotonic);
            return if ((state & 0b11) == Waiting) @intToPtr(*Task, state) else null;
        }

        fn consumeSignalWith(self: *@This(), update: usize) !?usize {
            var state = @atomicLoad(usize, &self.state, .Monotonic);
            while (true) {
                switch ((state & 0b11)) {
                    Empty => return null,
                    Waiting => return error.ContendedWaiting,
                    Ready, Close => if (@cmpxchgWeak(usize, &self.state, state, update, .Monotonic, .Monotonic)) |new_state| {
                        state = new_state;
                        continue;
                    } else return state,
                    else => unreachable,
                }
                @fence(.Acquire);
            }
        }

        pub async fn wait(self: *@This()) !?u32 {
            while (true) {
                // CONSUMER: try and consume an event without blocking
                if (try consumeSignalWith(Empty)) |state|
                    return if ((state & 0b11) == Ready) DecodeReady(state) else null;

                // no event was found, try and suspend / reschedule until it is woken up by `signal()`
                // check once more if an event was set during the suspend block before rescheduling
                var result: !?usize = null;
                suspend {
                    var task = Task { .link = null, .frame = @frame() };
                    if (consumeSignalWith(@ptrToInt(task.frame) | Waiting) catch |e| {
                        result = e;
                        resume task.frame;
                    }) |state| {
                        result = state;
                        resume task.frame;
                    } else {
                        task.reschedule();
                    }
                }

                // try and return a result if it was set, else jump back and try to consume the event again
                if (try result) |state|
                    return if ((state & 0b11) == Ready) DecodeReady(state) else null;
            }
        }
    };
};

const WinSock = struct {
    pub const Handle = system.HANDLE;
    
    pub fn initAll() !void {
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

        try findWSAFunc(dummy, WSAID_ACCEPTEX, &AcceptEx, error.WSAIoctlAcceptEx);
        try findWSAFunc(dummy, WSAID_CONNECTEX, &ConnectEx, error.WSAIoctlConnectEx);
    }

    pub fn deinitAll() void {
        _ = WSACleanup();
    }

    fn findWSAFunc(dummy_socket: HANDLE, func_guid: GUID, function: var, comptime err: anyerror) !void {
        var guid: GUID = func_guid;
        var dwBytes: system.DWORD = undefined;
        if (WSAIoctl(
            dummy_socket,
            SIO_GET_EXTENSION_FUNCTION_POINTER,
            @ptrCast(system.PVOID, &guid),
            @sizeOf(@typeOf(guid)),
            @ptrCAst(system.PVOID, function),
            @sizeOf(@typeInfo(function)),
            &dwBytes,
            null,
            null,
        ) != 0)
            return err;
    }

    const AF_UNSPEC: system.DWORD = 0;
    const AF_INET: system.DWORD = 2;
    const AF_INET6: system.DWORD = 6;
    const SOCK_STREAM: system.DWORD = 1;
    const SOCK_DGRAM: system.DWORD = 2;
    const SOCK_RAW: system.DWORD = 3;
    const IPPROTO_RAW: system.DWORD = 0;
    const IPPROTO_TCP: system.DWORD = 6;
    const IPPROTO_UDP: system.DWORD = 17;

    const WSAID_ACCEPTEX: GUID = GUID {
        .Data1 = 0xb5367df1,
        .Data2 = 0xcbac,
        .Data3 = 0x11cf,
        .Data4 = [_]u8 { 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
    };

    const WSAID_CONNECTEX: GUID = GUID {
        .Data1 = 0x25a207b9,
        .Data2 = 0xddf3,
        .Data3 = 0x4660,
        .Data4 = [_]u8 { 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
    };

    const GUID = extern struct {
        Data1: c_ulong,
        Data2: c_ushort,
        Data3: c_ushort,
        Data4: [8]u8,
    };

    const WSABUF = extern struct {
        len: system.ULONG,
        buf: [*]const u8,
    };

    const WSAData = extern struct {
        wVersion: system.WORD,
        wHighVersion: system.WORD,
        iMaxSockets: c_ushort,
        iMaxUdpDg: c_ushort,
        lpVendorInfo: [*]u8,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
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

    extern "ws2_32" stdcallcc fn socket(
        dwAddressFamily: system.DWORD,
        dwSocketType: system.DWORD,
        dwProtocol: system.DWORD,
    ) HANDLE;

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
