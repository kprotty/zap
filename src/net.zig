const os = @import("os.zig");
const memory = @import("memory.zig");
const atomic = @import("atomic.zig");
const scheduler = @import("scheduler.zig");

pub const Poller = struct {
    pub var waiters: u32 = 0;
    pub var last_polled: u64 = 0;
    
    iocp: os.HANDLE,

    inline fn maxConcurrency() DWORD {
        return @intCast(DWORD, scheduler.Worker.all.len);
    }

    pub fn init(self: *Poller) !void {
        var wsa_data: os.WSADATA = undefined;
        if (os.WSAStartup(0x202, &wsa_data) != 0)
            return error.WinsockStartup;
        self.iocp = os.CreateIoCompletionPort(os.INVALID_HANDLE, null, null, maxConcurrency())
            orelse return error.PollInit;
    }

    pub fn deinit(self: *Poller) void {
        _ = os.CloseHandle(self.iocp);
        _ = os.WSACleanup();
    }

    pub const Entry = struct {
        reader: Channel,
        writer: Channel,

        pub const Channel = struct {
            current: ?*scheduler.Task,
            overlapped: *os.OVERLAPPED,
            queue: atomic.Stack(scheduler.Task),
        };
    };

    pub fn register(self: *Poller, handle: os.HANDLE, entry: *Entry) !void {
        _ = CreateIoCompletionPort(
            self.iocp,
            handle,
            memory.ptrCast(?*os.ULONG, entry),
            maxConcurrency()
        ) orelse return error.PollRegister;
    }

    pub fn poll(self: *Poller, blocking: bool) ?*scheduler.Task {
        var overlapped_entries: [64]OVERLAPPED_ENTRY = undefined;
        var task_list: ?*scheduler.Task = null;
        var events = overlapped_entries[0..];

        _ = os.GetQueuedCompletionStatusEx(
            self.iocp,
            events[0..].ptr,
            @intCast(os.ULONG, events.len),
            memory.ptrCast(*os.ULONG, &events.len),
            if (blocking) os.INFINITE else os.DWORD(0),
        );

        for (events) |event| {
            const entry = memory.ptrCast(*Entry, event.lpCompletionKey);
            const channel = if (event.lpOverlapped == entry.reader.overlapped) &entry.reader else &entry.writer;
            channel.overlapped.InternalHigh = @intToPtr(*os.ULONG, usize(event.dwNumberOfBytesTransferred));
            
            const task = @atomicRmw(?*scheduler.Task, &channel.current, .Xchg, channel.queue.pop(), .SeqCst);
            task.next = task_list;
            task_list = task;
        }
        
        return task_list;
    }
};

pub const Socket = struct {
    entry: Poller.Entry,

    pub async fn read(self: *Socket, buffer: []u8) ![]u8 {
        var overlapped: os.OVERLAPPED = undefined;
        @memset(memory.ptrCast([*]u8, &overlapped), 0, @sizeOf(os.OVERLAPPED));

    }
};

