const std = @import("std");
const atomic = @import("atomic.zig");
const scheduler = @import("scheduler.zig");

pub const Poller = struct {
    pub var last_polled: u64 = undefined;

    iocp: HANDLE,

    inline fn maxConcurrency() DWORD {
        return @truncate(DWORD, scheduler.Worker.all.len);
    }

    pub fn init(self: *Poller) !void {
        var wsa_data: WSADATA = undefined;
        if (WSAStartup(0x202, &wsa_data) != 0)
            return error.WsaStartup;
        self.iocp = CreateIoCompletionPort(INVALID_HANDLE, null, null, maxConcurrency())
            orelse return error.PollInit;
    }

    pub fn deinit(self: *Poller) void {
        _ = CloseHandle(self.iocp);
        _ = WSACleanup();
    }

    pub fn register(self: *Poller, handle: HANDLE, entry: *Entry) !void {
        const entry_ptr = @ptrCast(?*ULONG, @alignCast(@alignOf(?*ULONG), entry));
        _ = CreateIoCompletionPort(self.iocp, handle, entry_ptr, maxConcurrency())
            orelse return error.PollRegister;
    }

    pub fn poll(self: *Poller, block: bool) ?*scheduler.Task {
        var entries_found: ULONG = undefined;
        var task_list: ?*scheduler.Task = null;
        var entries: [64]OVERLAPPED_ENTRY = undefined;
        
        if (GetQueuedCompletionStatusEx(
            self.iocp,
            entries[0..].ptr,
            ULONG(entries.len),
            &entries_found,
            if (block) INFINITE else 0,
            FALSE,
        ) == FALSE or entries_found == 0)
            return null;
        
        for (entries[0..entries_found]) |entry| {
            const poll_entry = @ptrCast(*Entry, @alignCast(@alignOf(*Entry), entry.lpCompletionKey));
            const port = @fieldParentPtr(Entry.Port, "overlapped", entry.lpOverlapped);
            var flags: DWORD = undefined;
            const had_error = WSAGetOverlappedResult(
                poll_entry.socket,
                entry.lpOverlapped,
                &entry.dwNumberOfBytesTransferred,
                FALSE,
                &flags,
            ) == FALSE;

            port.transferred = if (had_error) null else entry.dwNumberOfBytesTransferred;
            if (task_list) |task| port.waiting.next = task;
            task_list = port.waiting;
        }

        return task_list;
    }

    pub const Entry = struct {
        socket: SOCKET,
        reader: Port,
        writer: Port,

        pub const Port = struct {
            transferred: ?DWORD,
            overlapped: OVERLAPPED,
            waiting: *scheduler.Task,
            backlog: atomic.Stack(scheduler.Task),
        };
    };
};

pub const Socket = struct {

}

const BOOL = c_int;
const WORD = u16;
const DWORD = u32;
const ULONG = u32;
const HANDLE = *c_void;
const SOCKET = HANDLE;

const TRUE: BOOL = 1;
const FALSE: BOOL = 0;
const INFINITE: DWORD = ~DWORD(0);
const INVALID_HANDLE: HANDLE = ~HANDLE(0);

const OVERLAPPED = extern struct {
    Internal: *ULONG,
    InternalHigh: *ULONG,
    Offset: DWORD,
    OffsetHigh: DWORD,
    hEvent: HANDLE,
};

const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: ?*ULONG,
    lpOverlapped: *OVERLAPPED,
    Internal: *ULONG,
    dwNumberOfBytesTransferred: DWORD,
};

extern "kernel32" stdcallcc fn CloseHandle(
    hObject: HANDLE,
) BOOL;

extern "kernel32" stdcallcc fn CreateIoCompletionPort(
    FileHandle: HANDLE,
    ExistingCompletionPort: ?HANDLE,
    CompletionKey: ?*ULONG,
    NumberOfConcurrentThreads: DWORD,
) ?HANDLE;

extern "kernel32" stdcallcc fn GetQueuedCompletionStatusEx(
    CompletionPort: HANDLE,
    lpCompetionPortEntries: [*]OVERLAPPED_ENTRY,
    ulCount: ULONG,
    ulNumEntriesRemoved: *ULONG,
    dwMilliseconds: DWORD,
    fAlertable: BOOL,
) BOOL;

const WSADATA = extern struct {
    wVersion: WORD,
    wHighVersion: WORD,
    iMaxSockets: c_ushort,
    iMaxUdpDg: c_ushort,
    lpVendorInfo: [*]const u8,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
};

extern "ws2_32" stdcallcc fn WSACleanup() c_int;
extern "ws2_32" stdcallcc fn WSAStartup(
    wVersionRequired: WORD,
    lpWSAData: *WSADATA,
) c_int;

extern "ws2_32" stdcallcc fn WSAGetOverlappedResult(
    socket: SOCKET,
    lpOverlapped: *OVERLAPPED,
    lpcbTransfer: *DWORD,
    fWait: BOOL,
    lpdwFlags: *DWORD,
) BOOL;