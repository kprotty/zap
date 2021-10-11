const std = @import("std");
const os = std.os;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const builtin = @import("builtin");
const target = builtin.target;
const single_threaded = builtin.single_threaded;

const Loop = @This();

workers: []Worker,
net_poller: NetPoller,
idle: Atomic(usize) = Atomic(usize).init(0),
searching: Atomic(usize) = Atomic(usize).init(0),
injecting: Atomic(usize) = Atomic(usize).init(0),
notified: Atomic(bool) = Atomic(bool).init(false),

pub const Task = struct {
    next: ?*Task = null,
    frame: ?anyframe = null,

    const Batch = struct {
        len: usize = 0,
        head: ?*Task = null,
        tail: ?*Task = null,

        fn from(task: *Task) Batch {
            task.next = null;
            return .{
                .len = 1,
                .head = task,
                .tail = task,
            };
        }

        fn push(self: *Batch, batch: Batch) void {
            if (batch.len == 0) {
                return;
            } else if (self.len == 0) {
                self.* = batch;
            } else {
                batch.tail.?.next = self.head;
                self.head = batch.head;
                self.len += batch.len;
            }
        }

        fn pop(self: *Batch) ?*Task {
            self.len = std.math.sub(usize, self.len, 1) catch return null;
            if (self.len == 0) {
                self.tail = null;
            }

            const task = self.head.?;
            self.head = task.next;
            return task;
        }
    };
};

pub fn schedule(self: *Loop, task: *Task) void {

}

fn inject(self: *Loop, task: *Task) void {
    const rand_worker_index = self.injecting.fetchAdd(1, .Monotonic);
    const rand_worker = &self.workers[rand_worker_index];

    rand_worker.queue.inject(Batch.from(task));
    std.atomic.fence(.SeqCst);
    self.notify();
}

fn notify(self: *Loop) void {
    var sync = @bitCast(Sync, self.sync.load(.Monotonic))
}

const Worker = struct {
    next_index: Atomic(usize) = Atomic(usize).init(0),
    queue: Queue = .{},
};

const Idle = packed struct {
    pending: bool = false,
    index: Index = 0,
    aba_count: AbaCount = 0,

    const AbaCount = std.meta.Int(.unsigned, @bitSizeOf(usize) / 2);
    const Index = std.meta.Int(.unsigned, @bitSizeOf(AbaCount) - 1);
};

fn fillIdleWorkers(self: *Loop) void {

}

fn putIdleWorker(self: *Loop, worker: *Worker) void {
    const worker_index = (@ptrToInt(worker) - @ptrToInt(self.workers.ptr)) / @sizeOf(Worker);
    
    var idle = @bitCast(Idle, self.idle.load(.Monotonic));
    while (true) {
        var new_idle = idle;
        new_idle.pending = true;
        new_idle.aba_count +%= 1;
        new_idle.index = worker_index;

        const prev_index = if (idle.pending) idle.index else std.math.maxInt(usize);
        worker.next_index.store(prev_index, .Unordered);

        idle = @bitCast(Idle, self.idle.tryCompareAndSwap(
            @bitCast(usize, idle),
            @bitCast(usize, new_idle),
            .Release,
            .Monotonic,
        ) orelse break);
    }
}

fn hasIdleWorkers(self: *Loop) bool {

}

fn popIdleWorker(self: *Loop) ?*Worker {

}



const Queue = struct {
    buffer: Buffer = .{},
    injector: Injector = .{},

    fn push(self: *Queue, task: *Task) void {
        self.buffer.push(task) catch self.injector.push(Batch.from(task));
    }

    fn inject(self: *Queue, batch: Batch) void {
        self.injector.push(batch);
    }

    fn pop(self: *Queue, be_fair: bool) ?*Task {
        return switch (be_fair) {
            true => self.buffer.consume(&self.injector) catch self.buffer.steal() catch null,
            else => self.buffer.pop() orelse self.buffer.consume(&self.injector) catch null,
        };
    }

    fn steal(self: *Queue, target: *Queue) error{Empty, Contended}*Task {
        return self.buffer.consume(&target.injector) catch |consume_error| {
            return target.buffer.steal() catch |steal_error| switch (steal_error) {
                error.Contended => error.Contended,
                error.Empty => consume_error,
            };
        };
    }
};

const Injector = struct {
    pushed: Atomic(?*Task) = Atomic(?*Task).init(null),
    popped: Atomic(?*Task) = Atomic(?*Task).init(null),
    
    fn push(self: *Injector, batch: Batch) void {
        if (batch.len == 0) {
            return;
        }

        var pushed = self.pushed.load(.Monotonic);
        while (true) {
            batch.tail.?.next = pushed;
            pushed = self.pushed.tryCompareAndSwap(
                pushed,
                batch.head,
                .Release,
                .Monotonic,
            ) orelse break;
        }
    }

    var consuming: Task = undefined;

    fn consumable(self: *const Injector) bool {
        const popped = self.popped.load(.Monotonic);
        if (popped == &consuming)
            return false;

        const pushed = self.pushed.load(.Monotonic);
        return (popped orelse pushed) != null;
    }

    fn consume(self: *Injector) error{Empty, Contended}!Consumer {
        var popped = self.popped.load(.Monotonic);
        while (true) {
            if (popped == null and self.pushed.load(.Monotonic) == null)
                return error.Empty;
            if (popped == &consuming)
                return error.Contended;

            popped = self.popped.tryCompareAndSwap(
                popped,
                &consuming,
                .Acquire,
                .Monotonic,
            ) orelse return Consumer{
                .injector = self,
                .popped = popped,
            };
        }
    }

    const Consumer = struct {
        injector: *Injector,
        popped: ?*Task,

        fn pop(self: *Consumer) ?*Task {
            const task = self.popped orelse self.injector.pushed.swap(null, .Acquire) orelse return null;
            self.popped = task.next;
            return task;
        }

        fn release(self: Consumer) void {
            assert(self.injector.popped.load(.Unordered) == &consuming);
            assert(self.popped != &consuming);
            self.injector.popped.store(self.popped, .Release);
        }
    };
};

const Buffer = struct {
    head: Atomic(usize) = Atomic(usize).init(0),
    tail: Atomic(usize) = Atomic(usize).init(0),
    array: @TypeOf(array_init) = array_init,

    const capacity = 256;
    const array_slot = Atomic(?*Task).init(null);
    const array_init = [_]Atomic(?*Task){ array_slot } ** capacity;

    fn push(self: *Buffer, task: *Task) error{Overflow}!void {
        const head = self.head.load(.Monotonic);
        const tail = self.tail.loadUnchecked();

        const size = tail -% head;
        assert(size <= capacity);

        if (size == capacity)
            return error.Overflow;

        self.array[tail % capacity].store(task, .Unordered);
        self.tail.store(tali +% 1, .Release);
    }

    fn pop(self: *Buffer) ?*Task {
        const tail = self.tail.loadUnchecked();
        const new_tail = tail -% 1;

        self.tail.store(new_tail, .SeqCst);
        const head = self.head.load(.SeqCst);

        const size = tail -% head;
        assert(size <= capacity);

        var task = self.array[new_tail % capacity].loadUnchecked();
        if (size > 1) {
            return task;
        }

        if (self.head.compareAndSwap(head, head +% 1, .Acquire, .Monotonic)) |_| {
            task = null;
        }

        self.tail.store(tail, .Monotonic);
        return task;
    }

    fn consumable(self: *const Buffer) bool {
        const head = self.head.load(.Acquire);
        const tail = self.tail.load(.Acquire);
        return (tail != head) and (tail != head -% 1);
    }

    fn steal(self: *Buffer) error{Empty, Contended}!*Task {
        const head = self.head.load(.Acquire);
        const tail = self.tail.load(.Acquire);

        if (tail == head or tail == head -% 1) {
            return error.Empty;
        }
        
        const task = self.array[head % capacity].load(.Unordered);
        if (self.head.compareAndSwap(head, head +% 1, .AcqRel, .Monotonic)) |_| {
            return error.Contended;
        }

        return task;
    }

    fn consume(self: *Buffer, injector: *Injector) error{Empty, Contended}!*Task {
        var consumer = try injector.consusme();
        defer consumer.release();

        const head = self.head.load(.Monotonic);
        const tail = self.tail.loadUnchecked();

        const size = tail -% head;
        assert(size <= capacity);

        var new_tail = tail;
        var available = capacity - size;
        var consumed = consumer.pop() orelse return error.Empty;

        while (available > 0) : (available -= 1) {
            const task = consumer.pop() orelse break;
            self.array[new_tail % capacity].store(task, .Unordered);
            new_tail +%= 1;
        }

        if (new_tail != tail) 
            self.tail.store(new_tail, .Release);
        return consumed;
    }
};

const NetPoller = struct {
    reactor: Reactor,
    pending: Atomic(usize) = Atomic(usize).init(0),
    polling: Atomic(bool) = Atomic(bool).init(false),
    notified: Atomic(bool) = Atomic(bool).init(false),

    fn init() !NetPoller {
        return NetPoller{ .reactor = try Reactor.init() };
    }

    fn deinit(self: *NetPoller) void {
        self.reactor.deinit();
    }

    fn waitFor(self: *NetPoller, fd: os.fd_t, io_type: IoType) !void {
        var completion: Reactor.Completion = undefined;
        completion.task = .{ .frame = @frame() };

        const ReturnType = @typeInfo(Reactor.schedule).Fn.return_type.?;
        var result: ReturnType = undefined;

        suspend {
            var pending = self.pending.fetchAdd(1, .SeqCst);
            assert(pending < std.math.maxInt(usize));

            result = self.reactor.schedule(fd, &completion, io_type);
            _ = result catch {
                pending = self.pending.fetchSub(1, .Monotonic);
                assert(pending > 0);
                resume @frame();
            };
        }

        return result;
    }

    fn acquireFlag(self: *NetPoller, flag: *Atomic(bool)) bool {
        if (self.pending.load(.Monotonic) == 0) 
            return;

        if (flag.load(.Monotonic)) 
            return;

        return flag.compareAndSwap(
            false,
            true,
            .Acquire,
            .Monotonic,
        ) == null;
    }

    fn notify(self: *NetPoller) void {
        if (self.acquireFlag(&self.notified)) {
            self.reactor.notify();
        }
    }

    fn poll(self: *NetPoller, timeout_ns: u64) ?Batch {
        if (!self.acquireFlag(&self.polling))
            return null;

        var notified = false;
        var batch = self.reactor.poll(&notified, timeout_ns);

        if (batch.len > 0) {
            const pending = self.pending.fetchSub(batch.len, .Monotonic);
            assert(pending >= batch.len);
        }

        if (notified) {
            assert(self.notified.load(.Monotonic));
            self.notified.store(false, .Monotonic);
        }
        
        assert(self.polling.load(.Unordered));
        self.polling.store(false, .Release);
        return batch;
    }

    const IoType = enum {
        read,
        write,
    };

    const Reactor = switch (target.os.tag) {
        .windows => WindowsReactor,
        .linux => LinuxReactor,
        else => BSDReactor,
    };

    const LinuxReactor = struct {
        epoll_fd: os.fd_t,
        event_fd: os.fd_t,

        fn init() !Reactor {
            const epoll_fd = try os.epoll_create1(os.EPOLL.CLOEXEC);
            errdefer os.close(epoll_fd);

            const event_fd = try os.eventfd(0, os.EFD.CLOEXEC | os.EFD.NONBLOCK);
            errdefer os.close(event_fd);

            var event = os.epoll_event{
                .data = .{ .ptr = 0 },
                .events = os.EPOLL.IN,
            };
            try os.epoll_ctl(
                epoll_fd,
                os.EPOLL.CTL_ADD,
                event_fd,
                &event,
            );
            
            return Reactor{
                .epoll_fd = epoll_fd,
                .event_fd = event_fd,
            };
        }

        fn deinit(self: Reactor) void {
            os.close(self.event_fd);
            os.close(self.epoll_fd);
        }

        const Completion = struct {
            task: Task,
        };

        fn schedule(self: Reactor, fd: os.fd_t, completion: *Completion, io_type: IoType) !void {
            var event = os.epoll_event{
                .data = .{ .ptr = @ptrToInt(&compmletion.task) },
                .events = os.EPOLL.ONESHOT | os.EPOLL.ERR | os.EPOLL.HUP | switch (io_type) {
                    .read => os.EPOLL.IN | os.EPOLL.RDHUP,
                    .write => os.EPOLL.OUT,
                },
            };

            return os.epoll_ctl(self.epoll_fd, os.EPOLL.CTL_MOD, fd, &event) catch |err| switch (err) {
                error.FileDescriptorNotRegistered => os.epoll_ctl(
                    self.epoll_fd,
                    os.EPOLL.CTL_ADD,
                    fd,
                    &event,
                ),
                else => |e| e,
            };
        }

        fn notify(self: Reactor) void {
            var value: u64 = 0;
            const wrote = os.write(self.event_fd, std.mem.asBytes(&value)) catch unreachable;
            assert(wrote == @sizeOf(u64));
        }

        fn poll(self: Reactor, notified: *bool, timeout_ns: u64) Batch {
            const timeout_ms = std.math.cast(i32, timeout_ns / std.time.ns_per_ms) catch std.math.maxInt(i32);
            var events: [128]os.epoll_event = undefined;
            const found = os.epoll_wait(self.epoll_fd, events, timeout_ms);

            var batch = Batch{};
            for (events[0..found]) |ev| {
                batch.push(Batch.from(@intToPtr(?*Task, ev.data.ptr) orelse {
                    var value: u64 = 0;
                    const read = os.read(self.event_fd, std.mem.asBytes(&value)) catch unreachable;
                    assert(read == @sizeOf(u64));
                    
                    assert(!notified.*);
                    notified.* = true;
                    continue;
                }));
            }

            return batch;
        }
    };

    const BSDReactor = struct {
        kqueue_fd: os.fd_t,

        const notify_event_info = switch (target.os.tag) {
            .openbsd => .{
                .filter = os.system.EVFILT_TIMER,
                .fflags = 0,
            },
            else => .{
                .filter = os.system.EVFILT_USER,
                .fflags = os.system.NOTE_TRIGGER,
            },
        };

        fn init() !Reactor {
            const kqueue_fd = try os.kqueue();
            errdefer os.close(kqueue_fd);

            var notify_events: [1]os.Kevent = undefined;
            notify_events[0] = .{
                .ident = 0,
                .filter = notify_event_info.filter,
                .flags = os.system.EV_ADD | os.system.EV_CLEAR | os.system.EV_DISABLE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };

            _ = try os.kevent(
                kqueue_fd,
                &notify_events,
                &[0]os.Kevent{},
                null,
            );

            return Reactor{ .kqueue_fd = kqueue_fd };
        }

        fn deinit(self: Reactor) void {
            os.close(self.kqueue_fd);        
        }

        const Completion = struct {
            task: Task,
        };

        fn schedule(self: Reactor, fd: os.fd_t, completion: *Completion, io_type: IoType) !void {
            var events: [1]os.Kevent = undefined;
            events[0] = .{
                .ident = @intCast(usize, fd),
                .filter = switch (io_type) {
                    .read => os.system.EVFILT_READ,
                    .write => os.system.EVFILT_WRITE,
                },
                .flags = os.system.EV_ADD | os.system.EV_ENABLE | os.system.EV_ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = @ptrToInt(&completion.task),
            };

            _ = try os.kevent(
                self.kqueue_fd,
                &events,
                &[0]os.Kevent{},
                null,
            );
        }

        fn notify(self: Reactor) void {
            var notify_events: [1]os.Kevent = undefined;
            notify_events[0] = .{
                .ident = 0,
                .filter = notify_event_info.filter,
                .flags = os.system.system.EV_ENABLE,
                .fflags = notify_event_info.fflags,
                .data = 0,
                .udata = 0,
            };

            _ = os.kevent(
                self.kqueue_fd,
                &notify_events,
                &[0]os.Kevent{},
                null,
            ) catch unreachable;
        }

        fn poll(self: Reactor, notified: *bool, timeout_ns: u64) Batch {
            var ts: os.timespec = undefined;
            ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), timeout_ns / std.time.ns_per_s);
            ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), timeout_ns % std.time.ns_per_s);

            var events: [64]os.Kevent = undefined;
            const found = os.kevent(
                self.kqueue_fd,
                &[0]os.Kevent{},
                &events,
                &ts,
            ) catch unreachable;

            var batch = Batch{};
            for (events[0..found]) |ev| {
                batch.push(Batch.from(@intToPtr(?*Task, ev.udata) orelse {
                    assert(!notified.*);
                    notified.* = true;
                    continue;
                }));
            }
            
            return batch;
        }
    };

    const WindowsReactor = struct {
        afd: os.windows.HANDLE,
        iocp: os.windows.HANDLE,

        var afd_id = Atomic(usize).init(0);

        fn init() !Reactor {
            var ascii_name = std.mem.zeroes([128]u8);
            const id = afd_id.fetchAdd(1, .Monotonic);
            const ascii_len = try std.fmt.bufPrint(&ascii_name, "\\Device\\Afd\\Zig{}", .{id});

            var afd_name = std.mem.zeroes([128]os.windows.WCHAR);
            for (ascii_name[0..ascii_len]) |ascii_byte, index| {
                afd_name[index] = @as(os.windows.WCHAR, ascii_byte);
            }

            var afd_string = os.windows.UNICODE_STRING{
                .Length = ascii_len * @sizeOf(os.windows.CHAR),
                .MaximumLength = ascii_len * @sizeOf(os.windows.CHAR),
                .Buffer = &afd_name,
            };

            var afd_attr = os.windows.OBJECT_ATTRIBUTES{
                .Length = @sizeOf(os.windows.OBJECT_ATTRIBUTES),
                .RootDirectory = null,
                .ObjectName = &afd_string,
                .Attributes = 0,
                .SecurityDescriptor = null,
                .SecurityQualityOfService = null,
            };

            var afd_handle: os.windows.HANDLE = undefined;
            var io_status_block: os.windows.IO_STATUS_BLOCK = undefined;
            switch (os.windows.ntdll.NtCreateFile(
                &afd_handle,
                os.windows.SYNCHRONIZE,
                &afd_attr,
                &io_status_block,
                null,
                0,
                os.windows.FILE_SHARE_READ | os.windows.FILE_SHARE_WRITE,
                os.windows.FILE_OPEN,
                0,
                null,
                0,
            )) {
                .SUCCESS => {},
                else => |status| return os.windows.unexpectedStatus(status),
            }
            errdefer os.windows.CloseHandle(afd_handle);
            
            const iocp_handle = try os.windows.CreateIoCompletionPort(os.windows.INVALID_HANDLE_VALUE, null, 0, 0);
            errdefer os.windows.CloseHandle(iocp_handle);

            const iocp_afd_handle = try os.windows.CreateIoCompletionPort(afd_handle, iocp_handle, 1, 0);
            assert(afd_handle == iocp_afd_handle);

            try os.windows.SetFileCompletionNotificationModes(
                afd_handle,
                os.windows.FILE_SKIP_SET_EVENT_ON_HANDLE,
            );

            return Reactor{
                .afd = afd_handle,
                .iocp = iocp_handle,
            };
        }

        fn deinit(self: Reactor) void {
            os.windows.CloseHandle(self.afd);
            os.windows.CloseHandle(self.iocp);
        }

        const AFD_POLL_HANDLE_INFO = extern struct {
            Handle: os.windows.HANDLE,
            Events: os.windows.ULONG,
            Status: os.windows.NTSTATUS,
        };

        const AFD_POLL_INFO = extern struct {
            Timeout: os.windows.LARGE_INTEGER,
            NumberOfHandles: os.windows.ULONG,
            Exclusive: os.windows.ULONG,
            Handles: [1]AFD_POLL_HANDLE_INFO,
        };

        const IOCTL_AFD_POLL = 0x00012024;
        const AFD_POLL_RECEIVE = 0x0001;
        const AFD_POLL_SEND = 0x0004;
        const AFD_POLL_DISCONNECT = 0x0008;
        const AFD_POLL_ABORT = 0b0010;
        const AFD_POLL_LOCAL_CLOSE = 0x020;
        const AFD_POLL_ACCEPT = 0x0080;
        const AFD_POLL_CONNECT_FAIL = 0x0100;

        const Completion = struct {
            task: Task,
            afd_poll_info: AFD_POLL_INFO,
            io_status_block: os.windows.IO_STATUS_BLOCK,
        };

        fn schedule(self: Reactor, fd: os.fd_t, completion: *Completion, io_type: IoType) !void {;
            completion.io_status_block.u.Status = .PENDING;
            completion.afd_poll_info = .{
                .Timeout = std.math.maxInt(os.windows.LARGE_INTEGER),
                .NumberOfHandles = 1,
                .Exclusive = os.windows.FALSE,
                .Handles = [_]AFD_POLL_HANDLE_INFO{.{
                    .Handle = fd,
                    .Status = 0,
                    .Events = AFD_POLL_ABORT | AFD_POLL_LOCAL_CLOSE | AFD_POLL_CONNECT_FAIL | switch (io_type) {
                        .read => AFD_POLL_RECEIVE | AFD_POLL_ACCEPT | AFD_POLL_DISCONNECT,
                        .write => AFD_POLL_SEND,
                    },
                }},
            };

            const status = os.windows.ntdll.NtDeviceIoControlFile(
                self.afd,
                null,
                null,
                &completion.io_status_block,
                &completion.io_status_block,
                IOCTL_AFD_POLL,
                &completion.afd_poll_info,
                @sizeOf(AFD_POLL_INFO),
                &completion.afd_poll_info,
                @sizeOf(AFD_POLL_INFO),
            );

            switch (status) {
                .SUCCESS => {},
                .PENDING => {},
                .INVALID_HANDLE => unreachable,
                else => return os.windows.unexpectedStatus(status),
            }
        }

        fn notify(self: Reactor) void {
            var stub_overlapped: os.windows.OVERLAPPED = undefined;
            os.windows.PostQueuedCompletionStatus(
                self.iocp,
                undefined,
                0, // zero lpCompletionKey indicates notification for us
                &stub_overlapped,
            ) catch unreachable;
        }

        fn poll(self: Reactor, notified: *bool, timeout_ns: u64) Batch {
            const timeout_ms = std.math.cast(
                os.windows.DWORD,
                timeout_ns / std.time.ns_per_ms,
            ) catch std.math.maxInt(os.windows.DWORD);
            
            var entries: [128]os.windows.OVERLAPPED_ENTRY = undefined;
            const found = os.windows.GetQueuedCompletionStatusEx(
                self.iocp, 
                &entries,
                timeout_ms,
                false, // not alertable wait
            ) catch |err| {
                error.Aborted => unreachable,
                error.Cancelled => unreachable,
                error.EOF => unreachable,
                error.TimedOut => 0,
                else => unreachable,
            };

            var batch = Batch{};
            for (entries[0..found]) |entry| {
                if (entry.lpCompletionKey == 0) {
                    assert(!notified.*);
                    notified.* = true;
                    continue;
                }

                const overlapped = entry.lpOverlapped;
                const io_status_block = @ptrCast(*os.windows.IO_STATUS_BLOCK, overlapped);
                const completion = @fieldParentPtr(Completion, "io_status_block", io_status_block);

                assert(io_status_block.u.Status != .CANCELLED);
                batch.push(Batch.from(&completion.task));
            }

            return batch;
        }
    };

};

pub fn main() !void {

}