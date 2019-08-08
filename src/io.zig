const os = @import("os.zig");
const memory = @import("memory.zig");
const atomic = @import("atomic.zig");
const scheduler = @import("scheduler.zig");

pub const Stream = struct {
    reader: Channel,
    writer: Channel,

    pub const Channel = struct {
        pub const Error = error.ChannelClosed; // TODO: more specific errors?
        var invalid_overlapped: os.OVERLAPPED = undefined;

        /// The current overlapped being used for the channel.
        /// In order to acquire channel IO permissions, atomic CAS this with null.
        /// Set to &invalid_overlapped on channel error. Which all tasks should then give up on performing IO
        overlapped: ?*os.OVERLAPPED,
        /// The poor souls who failed the atomic CAS operation from above ^
        queue: atomic.Stack(scheduler.Task),

        /// TODO: Review the atomic ordering guarantees. They may not be correct
        pub async fn lock(self: *Channel, task: *scheduler.Task, overlapped: *os.OVERLAPPED) !void {
            @fence(.Release);
            if (@cmpxchgWeak(?*os.OVERLAPPED, &self.overlapped, null, overlapped, .Monotonic, .Monotonic)) |current| {
                if (current == &invalid_overlapped) 
                    return Error; // Give up, there was an error
                self.queue.push(task);
                suspend; // wait to be popped from the queue and resumed
                if (@atomicLoad(?*os.OVERLAPPED, &self.overlapped, .Monotonic) == &invalid_overlapped)
                    return Error; // Give up, there was an error
                self.overlapped = overlapped; // Can now perform IO operations on the channel
            }
        }

        pub fn unlock(self: *Channel, task: *scheduler.Task, had_error: bool) !void {
            // On success, enqueue the next task to run
            // If theres no next task, set the overlapped to null to reset the lock
            if (!had_error) {
                if (self.queue.pop()) |pending_task| {
                    task.thread.worker.run_queue.put(pending_task, true);
                } else {
                    atomic.store(?*os.OVERLAPPED, &self.overlapped, null, .Monotonic);
                    _ = @atomicRmw(usize, &Poller.waiters, .Sub, 1, .Release);
                }
                return;
            }
            
            // There was an error, set the overlapped state to invalid and requeue pending tasks
            _ = @atomicRmw(usize, &Poller.waiters, .Sub, 1, .Release);
            atomic.store(?*os.OVERLAPPED, &self.overlapped, &invalid_overlapped, .Monotonic);
            while (self.queue.pop()) |pending_task| {
                task.thread.worker.run_queue.put(pending_task, false);
            }

            @fence(.Acquire);
            return Error;
        }
    };
};

pub const Poller = struct {
    pub var waiters: usize = 0;
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

    // Should be registered on handle creation only once.
    // TODO: epoll_ctl(ADD) & kevent(EV_ADD) with edge triggering
    pub fn register(self: *Poller, handle: os.HANDLE, stream: *Stream) !void {
        _ = CreateIoCompletionPort(
            self.iocp,
            handle,
            memory.ptrCast(?*os.ULONG, stream),
            maxConcurrency()
        ) orelse return error.PollRegister;
    }

    pub fn poll(self: *Poller, blocking: bool) ?*scheduler.Task {
        var overlapped_entries: [64]OVERLAPPED_ENTRY = undefined;
        var task_list: ?*scheduler.Task = null;
        var entries = overlapped_entries[0..];

        // TODO: Should also check the result for os.FALSE?
        _ = os.GetQueuedCompletionStatusEx(
            self.iocp,
            entries[0..].ptr,
            @intCast(os.ULONG, entries.len),
            memory.ptrCast(*os.ULONG, &entries.len),
            if (blocking) os.INFINITE else os.DWORD(0),
        );

        for (entries) |entry| {
            // Get the corresponding stream & channel based on the completion key & overlapped.
            // Also use the InternalHigh to store dwNumberOfBytesTransferred.
            // This is safe since the overlapped wont go into a syscall later on unless reset
            const stream = memory.ptrCast(*Stream, entry.lpCompletionKey);
            const channel = if (entry.lpOverlapped == stream.reader.overlapped) &stream.reader else &stream.writer;
            channel.overlapped.InternalHigh = @intToPtr(?*os.ULONG, usize(entry.dwNumberOfBytesTransferred));

            // Add the task associated with the overlapped to the task list to be executed again.
            // HACK: This relies on the kernel not touching hEvent.
            // It shouldnt since we never call WSAGetOverlappedResult()
            const task = memory.ptrCast(*scheduler.Task, entry.lpOverlapped.hEvent);
            task.next = task_list;
            task_list = task;
        }
        
        return task_list;
    }
};


pub const Socket = struct {
    handle: os.SOCKET,
    stream: Stream,

    pub async fn read(self: *Socket, buffer: []u8) !void {
        try (await (async self.write_many([][]const u8 { buffer }) catch unreachable));
    }

    pub async fn write(self: *Socket, buffer: []u8) !void {
        try (await (async self.write_many([][]const u8 { buffer }) catch unreachable));
    }

    pub async fn read_many(self: *Socket, buffers: [][]u8) !void {
        try (await (async self.wsa_buffered_io(wsa_send, buffers, &self.stream.reader) catch unreachable));
    }

    pub async fn write_many(self: *Socket, buffers: [][]const u8) !void {
        try (await (async self.wsa_buffered_io(wsa_recv, buffers, &self.stream.writer) catch unreachable));
    }

    const IoOperation = fn(
        self: *Socket, 
        overlappend: *os.OVERLAPPED,
        buffers: []os.WSABUF,
        transferred: *os.DWORD,
    ) c_int;

    fn wsa_send(self: *Socket, overlapped: *os.OVERLAPPED, buffers: []os.WSABUF, transferred: *os.DWORD) c_int {
        return os.WSASend(self.handle, buffers.ptr, @intCast(os.DWORD, buffer.len), transferred, 0, &overlapped, null);
    }

    fn wsa_recv(self: *Socket, overlapped: *os.OVERLAPPED, buffers: []os.WSABUF, transferred: *os.DWORD) c_int {
        var flags: os.DWORD = undefined;
        return os.WSARecv(self.handle, buffers.ptr, @intCast(os.DWORD, buffer.len), transferred, &flags, &overlapped, null);
    }

    async fn wsa_buffered_io(self: *Socket, io_operation: IoOperation, channel: *Stream.Channel, buffers: [][]const u8) !void {
        const task = scheduler.Task.current;

        var had_error = false;
        var bytes_sent: os.ULONG = undefined;
        var overlapped: os.OVERLAPPED = undefined;
        var wsa_buffers = swapWSABuffers(buffers, true);

        defer swapWSABuffers(buffers, false);
        defer channel.unlock(task, had_error);

        // Lock the channel & reset the overlapped for every attempted IO request.
        // Keep performing IO requests until either the entire wsa_buffers is transferred or an error occurs.
        while (wsa_buffers.len > 0) {
            try (await (async channel.writer.lock(task, &overlapped) catch unreachable));
            @memset(memory.ptrCast([*]u8, &overlapped), 0, @sizeOf(os.OVERLAPPED));
            overlapped.hEvent = memory.ptrCast(os.HANDLE, task);

            if (io_operation(self.handle, &overlapped, wsa_buffers, &bytes_sent) != 0) {
                had_error = os.WSAGetLastError() != os.WSA_IO_PENDING;
                if (had_error) return Stream.Channel.Error else suspend; 
                had_error = overlapped.Interal != null;
                if (had_error) return;
            }

            var transferred = @ptrToInt(overlapped.InternalHigh);
            while (wsa_buffers.len > 0 and transferred > 0) {
                const current_buffer = wsa_buffers[0];
                wsa_buffers[0] = wsa_buffers[0][transferred..];
                transferred -= current_buffer.len;
                if (wsa_buffers[0].len == 0)
                    wsa_buffers = wsa_buffers[1..];
            }
        }
    }

    /// HACK: Convert slices to os.WSABUF in place by rearranging fields.
    /// Relies on zig slices being some struct { ptr: [*]const T, len: usize }.
    fn swapWSABuffers(buffers: [][]const u8, toWSABUF: bool) []os.WSABUF {
        for (buffers) |*buffer| {
            if (@ptrToInt(&buffer.len) > @ptrToInt(&buffer.ptr)) {
                // use volatile to not reorder the reads or writes when read casting or @memcpy()'ing
                // TODO: Find a better way instead of volatile. More so for this whole function ...
                if (toWSABUF) {
                    var wsabuf = os.WSABUF {
                        .ptr = memory.ptrCast(*volatile [*]const u8, &buffer.ptr).*,
                        .len = @intCast(os.DWORD, memory.ptrCast(*volatile usize, &buffer.len).*)
                    };
                    @memcpy(memory.ptrCast([*]u8, buffer), memory.ptrCast([*]const u8, &wsabuf), @sizeOf(os.WSABUF));
                } else {
                    const wsabuf = memory.ptrCast(*volatile []os.WSABUF, buffer).*;
                    *buffer = wsabuf.ptr[0..wsabuf.len];
                }
            }
        }

        var converted = slices;
        return memory.ptrCast(*[]os.WSABUF, &converted).*;
    }
};

