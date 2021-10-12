const std = @import("std");
const os = std.os;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;
const Allocator = std.mem.Allocator;

const builtin = @import("builtin");
const target = builtin.target;
const single_threaded = builtin.single_threaded;

const Loop = @This();

pub fn init(self: *Loop) !void {

}

pub fn deinit(self: *Loop) void {

}

pub fn schedule(self: *Loop, task: *Task) void {

}

pub const Task = struct {

};

const Worker = struct {

    pub const Group = struct {

    };
};

const Node = struct {

    pub const Queue = struct {

    };

    const Injector = struct {

    };

    const Buffer = struct {

    };
};

const Thread = struct {

    pub const Event = struct {
        state: Atomic(u32) = Atomic(u32).init(UNSET),

        const UNSET = 0;
        const WAITING = 1;
        const SET = 2;

        pub fn wait(self: *Event, timeout_ms: u64) error{TimedOut}!void {
            if (self.state.compareAndSwap(
                UNSET,
                WAITING,
                .Acquire,
                .Acquire,
            )) |state| {
                assert(state == SET);
                return;
            }

            var timestamp = 
        }

        pub fn set(self: *Event) void {

        }

        pub fn reset(self: *Event) void {

        }
    };

    pub const Lock = switch (target.os.tag) {
        .linux => if (link_libc) PosixLock else LinuxLock,
        .macos, .ios, .tvos, .watchos => DarwinLock,
        .windows => WindowsLock,
        else => PosixLock,
    };

    const DarwinLock = struct {
        oul: os.darwin.os_unfair_lock = .{},

        pub fn deinit(self: *Lock) void {
            self.* = undefined;
        }

        pub fn acquire(self: *Lock) void {
            os.darwin.os_unfair_lock_lock(&self.oul);
        }

        pub fn release(self: *Lock) void {
            os.darwin.os_unfair_lock_unlock(&self.oul);
        }
    };

    const WindowsLock = struct {
        srwlock: os.windows.SRWLOCK = os.windows.SRWLOCK_INIT,

        pub fn deinit(self: *Lock) void {
            self.* = undefined;
        }

        pub fn acquire(self: *Lock) void {
            os.windows.kernel32.AcquireSRWLockExclusive(&self.srwlock);
        }

        pub fn release(self: *Lock) void {
            os.windows.kernel32.ReleaseSRWLockExclusive(&self.srwlock);
        }
    };

    const PosixLock = struct {
        mutex: c.pthread_mutex_t = .{},

        pub fn deinit(self: *Lock) void {
            const rc = c.pthread_mutex_destroy(&self.mutex);
            assert(rc == .SUCCESS or rc == .INVAL);
        }

        pub fn acquire(self: *Lock) void {
            const rc = c.pthread_mutex_lock(&self.mutex);
            assert(rc == .SUCCESS);
        }

        pub fn release(self: *Lock) void {
            const rc = c.pthread_mutex_unlock(&self.mutex);
            assert(rc == .SUCCESS);
        }
    };

    const LinuxLock = struct {
        state: Atomic(u32) = Atomic(u32).init(UNLOCKED),

        const UNLOCKED = 0;
        const LOCKED = 1;
        const CONTENDED = 2;

        pub fn deinit(self: *Lock) void {
            assert(self.state.load(.Unordered) == UNLOCKED);
            self.* = undefined;
        }

        pub fn acquire(self: *Lock) void {
            var lock_state = self.state.swap(LOCKED, .Acquire);
            if (lock_state == UNLOCKED) {
                return;
            }

            var spin: u8 = 10;
            while (spin > 0) : (spin -= 1) {
                switch (self.state.load(.Monotonic)) {
                    UNLOCKED => _ = self.state.tryCompareAndSwap(
                        state, 
                        lock_state, 
                        .Acquire,
                        .Monotonic,
                    ) orelse return,
                    LOCKED => {},
                    CONTENDED => break,
                    else => unreachable, // invalid Lock state
                }
                std.atomic.spinLoopHint();
            }

            while (true) {
                switch (self.state.swap(CONTENDED, .Acquire)) {
                    UNLOCKED => return,
                    LOCKED, CONTENDED => {},
                    else => unreachable, // invalid Lock State
                }
                std.Thread.Futex.wait(&self.state, CONTENDED, null) catch unreachable;
            }
        }

        pub fn release(self: *Lock) void {
            switch (self.state.swap(UNLOCKED, .Release)) {
                UNLOCKED => unreachable, // unlocked an unlocked Lock
                LOCKED => {},
                CONTENDED => std.Thread.Futex.wake(&self.state, 1),
                else => unreachable, // invalid Lock state
            }
        }
    };
};

const Time = struct {
    pub const Queue = struct {

    };

    pub const Clock = struct {
        started: Timestamp,

        pub fn init() Clock {
            return .{ .started = Timestamp.now() };
        }

        /// Returns milliseconds since the Clock was initialized.
        /// The precision and monotonic properties depend on the OS implementaiton.
        pub fn now(self: *Clock) u64 {
            return Timestamp.now().since(self.started);
        }
    };

    pub const Timestamp = switch (target.os.tag) {
        // Uses InterruptTime instead of QPC as we use this time to sleep which uses the interrupt resolution anyway
        .windows => WindowsTimestamp,
        // Calls mach_continuous_time() internally which ticks while suspended:
        // https://opensource.apple.com/source/Libc/Libc-1439.40.11/gen/clock_gettime.c.auto.html
        .macos, .ios, .watchos, .tvos => PosixTimestamp(os.CLOCK.MONOTONIC_RAW),
        // On FreeBSD derivatives, this appears to have less overhead while still counting time suspend:
        // https://github.com/freebsd/freebsd-src/blob/60b0ad10dd0fc7ff6892ecc7ba3458482fcc064c/lib/libc/sys/__vdso_gettimeofday.c#L110
        .freebsd, .dragonfly => PosixTimestamp(os.CLOCK.UPTIME_FAST),
        // On Linux, MONOTONIC doesn't tick while suspended but BOOTTIME does.
        .linux => PosixTimestamp(os.CLOCK.BOOTTIME),
        // On other POSIX systems (excluding openbsd), MONOTONIC is generally the only available clock source which ticks while suspended.
        else => PosixTimestamp(os.CLOCK.MONOTONIC),
    };

    fn PosixTimestamp(comptime clock_id: u32) type {
        return struct {
            ts: os.timespec,

            pub fn now() Timestamp {
                // Choose the clock-source which reports time spent suspended
                const clock_id = switch (target.os.tag) {
                    .linux => os.CLOCK.BOOTTIME,
                    else => os.CLOCK.MONOTONIC,
                };

                var ts: os.timespec = undefined;
                os.clock_gettime(clock_id, &ts) catch unreachable;
                return .{ .ts = ts };
            }

            pub fn since(self: Timestamp, earlier: Timestamp) u64 {
                // This seems to be the only way to make timespecdiff branchless to LLVM.
                var ts: os.timespec = undefined;
                if (self.ts.tv_nsec - earlier.ts.tv_nsec < 0) {
                    ts.tv_sec = self.ts.tv_sec - earlier.ts.tv_sec - 1;
                    ts.tv_nsec = self.ts.tv_nsec - earlier.ts.tv_nsec + std.time.ns_per_s;
                } else {
                    ts.tv_sec = self.ts.tv_sec - earlier.ts.tv_sec;
                    ts.tv_nsec = self.ts.tv_nsec - earlier.ts.tv_nsec;
                }

                const whole = @intCast(u64, r.tv_sec) * std.time.ms_per_s;
                const part = @intCast(u32, r.tv_nsec) / std.time.ns_per_ms;
                return whole + part;
            }
        };
    }

    const WindowsTimestamp = struct {
        interrupt_time: windows.LONGLONG,

        const KSYSTEM_TIME = extern struct {
            Low: windows.ULONG,
            High: windows.LONG,
            High2: windows.LONG,
        };

        pub fn now() Timestamp {
            // Windows has this thing called KUSER_SHARED_DATA which is a
            // shared, read-only mapping of memory between the Kernel and all user processes.
            //
            // It exposes all sorts of useful information, but we're only interested in the InterruptTime:
            // https://www.geoffchappell.com/studies/windows/km/ntoskrnl/inc/api/ntexapi_x/kuser_shared_data/index.htm
            const KUSER_SHARED_DATA = 0x7FFE0000;
            const InterruptTime = @intToPtr(
                *volatile KSYSTEM_TIME,
                KUSER_SHARED_DATA + 0x08,
            );

            // 32bit systems lack an efficient way to atomically read 64bit values
            // so Windows uses a neat trick to cheaply read the KSYSTEM_TIME here.
            //
            // The kernel ensures that the High part of KSYSTEM_TIME is consistent using the High2.
            // When writing, it first updates High2, then Low, then High.
            // We must then read in the opposite order of High, then Low, then High2.
            // If our High result is the same as High2, then we succesfully read the 64bit value without interruption.
            // 
            // https://osm.hpi.de/pages/wrk/2007/08/getting-os-information-the-kuser_shared_data-structure/
            while (true) {
                const high = @atomicLoad(windows.ULONG, &InterruptTime.High, .Acquire); // Acq keeps Low + High2 below this read
                const low = @atomicLoad(windows.LONG, &InterruptTime.Low, .Acquire); // Acq keeps High2 below this read
                const high2 = @atomicLoad(windows.LONG, &InterruptTime.High2, .Monotonic);
                if (high == high2) {
                    return .{ .interrupt_time = (@as(windows.LONGLONG, high) << 32) + low };
                }
            }
        }

        pub fn since(self: Timestamp, earlier: Timestamp) u64 {
            // InterruptTime is in units of 100 nanoseconds
            const diff = @intCast(u64, self.interrupt_time - earlier.interrupt_time);
            return diff / (std.time.ns_per_ms / 100);
        }
    };
};

const NetPoller = struct {
    reactor: Reactor,
    pending: Atomic(usize) = Atomic(usize).init(0),
    polling: Atomic(bool) = Atomic(bool).init(false),
    notified: Atomic(bool) = Atomic(bool).init(false),

    pub fn init(self: *NetPoller) !void {
        self.* = .{ .reactor = undefined };
        try self.reactor.init();
    }

    pub fn deinit(self: *NetPoller) void {
        assert(self.pending.load(.Monotonic) == 0);
        assert(!self.polling.load(.Monotonic));
        self.reactor.deinit();
    }

    pub const IoType = enum {
        read,
        write,
    };

    pub fn waitFor(self: *NetPoller, fd: os.fd_t, io_type: IoType) !void {
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

    pub fn notify(self: *NetPoller) void {
        if (self.acquireFlag(&self.notified)) {
            self.reactor.notify();
        }
    }

    pub fn poll(self: *NetPoller, timeout_ms: u64) ?Task.List {
        if (!self.acquireFlag(&self.polling))
            return null;

        var notified = false;
        var list = self.reactor.poll(&notified, timeout_ms);

        if (list.len > 0) {
            const pending = self.pending.fetchSub(list.len, .Monotonic);
            assert(pending >= list.len);
        }

        if (notified) {
            assert(self.notified.load(.Monotonic));
            self.notified.store(false, .Monotonic);
        }
        
        assert(self.polling.load(.Unordered));
        self.polling.store(false, .Release);
        return list;
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

    const Reactor = switch (target.os.tag) {
        .freebsd, .openbsd, .netbsd, .dragonfly => BSDReactor,
        .macos, .ios, .tvos, .watchos => DarwinReactor,
        .windows => WindowsReactor,
        .linux => LinuxReactor,
        else => PosixReactor,
    };

    // TODO: select (?)
    const PosixReactor = @compileError("Platform doesn't support efficient I/O multiplexing");

    // epoll
    const LinuxReactor = struct {
        epoll_fd: os.fd_t,
        event_fd: os.fd_t,

        pub fn init(self: *Reactor) !void {
            self.epoll_fd = try os.epoll_create1(os.EPOLL.CLOEXEC);
            errdefer os.close(self.epoll_fd);

            self.event_fd = try os.eventfd(0, os.EFD.CLOEXEC | os.EFD.NONBLOCK);
            errdefer os.close(self.event_fd);

            try self.register(
                os.EPOLL.CTL_ADD,
                self.event_fd,
                os.EPOLL.IN, // level-triggered, readable
                0 // zero epoll_event.data.ptr for event_fd
            );
        }

        pub fn deinit(self: *Reactor) void {
            os.close(self.event_fd);
            os.close(self.epoll_fd);
        }

        pub const Completion = struct {
            task: Task,
        };

        pub fn schedule(self: *Reactor, fd: os.fd_t, io_type: IoType, completion: *Completion) !void {
            const ptr = @ptrToInt(&completion.task);
            const events = os.EPOLL.ONESHOT | switch (io_type) {
                .read => os.EPOLL.IN | os.EPOLL.RDHUP,
                .write => os.EPOLL.OUT,
            };

            return self.register(os.EPOLL.CTL_MOD, fd, events, ptr) catch |err| switch (err) {
                error.FileDescriptorNotRegistered => self.register(os.EPOLL_CTL_ADD, fd, events, ptr),
                else => err,
            };
        }

        fn register(self: *Reactor, op: u32, fd: os.fd_t, events: u32, user_data: usize) !void {
            var event = os.epoll_event{
                .data = .{ .ptr = user_data },
                .events = events | os.EPOLL.ERR | os.EPOLL.HUP,
            };
            try os.epoll_ctl(self.epoll_fd, op, fd, &event);
        }

        pub fn notify(self: *Reactor) void {
            var value: u64 = 0;
            const wrote = os.write(self.event_fd, std.mem.asBytes(&value)) catch unreachable;
            assert(wrote == @sizeOf(u64));
        }

        pub fn poll(self: *Reactor, notified: *bool, timeout_ms: u64) Task.List {
            var events: [128]os.epoll_event = undefined;
            const found = os.epoll_wait(
                self.epoll_fd, 
                &events,
                std.math.cast(i32, timeout_ms) catch std.math.maxInt(i32),
            );

            var list = Task.List{};
            for (events[0..found]) |ev| {
                list.push(@intToPtr(?*Task, ev.data.ptr) orelse {
                    var value: u64 = 0;
                    const read = os.read(self.event_fd, std.mem.asBytes(&value)) catch unreachable;
                    assert(read == @sizeOf(u64));
                    
                    assert(!notified.*);
                    notified.* = true;
                    continue;
                });
            }

            return list;
        }
    };

    // TODO: libdispatch (?)
    const DarwinReactor = BSDReactor;

    // kqueue
    const BSDReactor = struct {
        kqueue_fd: os.fd_t,

        pub fn init(self: *Reactor) !void {
            self.kqueue_fd = try os.kqueue();
            errdefer os.close(self.kqueue_fd);

            try self.kevent(.{
                .ident = 0, // zero-ident for notify event,
                .filter = notify_info.filter,
                .flags = os.system.EV_ADD | os.system.EV_CLEAR | os.system.EV_DISABLE,
                .fflags = 0, // fflags unused for notify_info.filter
                .udata = 0, // zero-udata for notify event
            });
        }

        pub fn deinit(self: *Reactor) void {
            os.close(self.kqueue_fd);
        }

        pub const Completion = struct {
            task: Task,
        };

        pub fn schedule(self: *Reactor, fd: os.fd_t, io_type: IoType, completion: *Completion) !void {
            try self.kevent(.{
                .ident = @intCast(usize, fd),
                .filter = switch (io_type) {
                    .read => os.system.EVFILT_READ,
                    .write => os.system.EVFILT_WRITE,
                },
                .flags = os.system.EV_ADD | os.system.EV_ENABLE | os.system.EV_ONESHOT,
                .fflags = 0, // fflags usused for read/write events
                .udata = @ptrToInt(&completion.task),
            });
        }

        pub fn notify(self: *Reactor) void {
            self.kevent(.{
                .ident = 0, // zero-ident for notify event
                .filter = notify_info.filter,
                .flags = os.system.EV_ENABLE,
                .fflags = notify_info.fflags,
                .udata = 0, // zero-udata for notify event
            }) catch unreachable;
        }

        fn kevent(self: *Reactor, info: anytype) !void {
            var events: [1]os.Kevent = undefined;
            events[0] = .{
                .ident = info.ident,
                .filter = info.filter,
                .flags = info.flags,
                .fflags = info.fflags,
                .data = 0,
                .udata = info.udata,
            };

            _ = try os.kevent(
                self.kqueue_fd,
                &events,
                &[0]os.Kevent{},
                null,
            );
        }

        pub fn poll(self: *Reactor, notified: *bool, timeout_ms: u64) Task.List {
            var ts: os.timespec = undefined;
            ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), timeout_ms / std.time.ms_per_s);
            ts.tv_sec = @intCast(@TypeOf(ts.tv_nsec), (timeout_ms % std.time.ms_per_s) * std.time.ns_per_ms);

            var events: [64]os.Kevent = undefined;
            const found = try os.kevent(
                self.kqueue_fd,
                &[0]os.Kevent{},
                &events,
                &ts,
            ) catch unreachable;

            var list = Task.List{};
            for (events[0..found]) |ev| {
                list.push(@intToPtr(?*Task, ev.udata) orelse {
                    assert(!notified.*);
                    notified.* = true;
                    continue;
                });
            }

            return list;
        }
    };

    // IOCP + AFD
    const WindowsReactor = struct {
        afd_handle: os.windows.HANDLE,
        iocp_handle: os.windows.HANDLE,

        var afd_id_gen = Atomic(usize).init(0);

        pub fn init(self: *Reactor) !void {
            var ascii_name = std.mem.zeroes([128]u8);
            const id = afd_id_gen.fetchAdd(1, .Monotonic);
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

            // Opening \Device\Afd without extended attributes
            // gives us a handle which can talk to the AFD driver
            var io_status_block: os.windows.IO_STATUS_BLOCK = undefined;
            switch (os.windows.ntdll.NtCreateFile(
                &self.afd_handle,
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
            errdefer os.windows.CloseHandle(self.afd_handle);
            
            self.iocp_handle = try os.windows.CreateIoCompletionPort(
                os.windows.INVALID_HANDLE_VALUE,
                null, // null completion port means we're creating one
                undefined, // the lpCompletionKey doesn't matter here
                0, // allow default num_cpus to be polling from the completion port
            );
            errdefer os.windows.CloseHandle(self.iocp_handle);

            const iocp_afd_handle = try os.windows.CreateIoCompletionPort(
                self.afd_handle, // register the AFD handle to IOCP
                self.iocp_handle,
                1, // lpCompletionKey of 1 to differentiate between notification
                0, // ignored since we're registering, not creating an IOCP
            );
            assert(afd_handle == iocp_afd_handle);

            // Make sure that AFD completions don't set 
            // the hEvent in the IO_STATUS_BLOCK since it doesn't have one.
            try os.windows.SetFileCompletionNotificationModes(
                self.afd_handle,
                os.windows.FILE_SKIP_SET_EVENT_ON_HANDLE,
            );
        }

        pub fn deinit(self: *Reactor) void {
            os.windows.CloseHandle(self.afd_handle);
            os.windows.CloseHandle(self.iocp_handle);
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

        pub const Completion = struct {
            task: Task,
            fd: os.fd_t,
            io_type: IoType,
            events: os.windows.DWORD,
            afd_poll_info: AFD_POLL_INFO,
            io_status_block: os.windows.IO_STATUS_BLOCK,
        };

        pub fn schedule(self: *Reactor, fd: os.fd_t, io_type: IoType, completion: *Completion) !void {
            completion.fd = fd;
            completion.io_type = io_type;
            completion.events = AFD_POLL_ABORT | AFD_POLL_LOCAL_CLOSE | AFD_POLL_CONNECT_FAIL | switch (io_type) {
                .read => AFD_POLL_RECEIVE | AFD_POLL_ACCEPT | AFD_POLL_DISCONNECT,
                .write => AFD_POLL_SEND,
            };

            completion.io_status_block.u.Status = .PENDING;
            completion.afd_poll_info = .{
                .Timeout = std.math.maxInt(os.windows.LARGE_INTEGER),
                .NumberOfHandles = 1,
                .Exclusive = os.windows.FALSE,
                .Handles = [_]AFD_POLL_HANDLE_INFO{.{
                    .Handle = fd,
                    .Status = 0,
                    .Events = completion.events,
                }},
            };

            const status = os.windows.ntdll.NtDeviceIoControlFile(
                self.afd_handle,
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

        pub fn notify(self: *Reactor) void {
            var stub_overlapped: os.windows.OVERLAPPED = undefined;
            os.windows.PostQueuedCompletionStatus(
                self.iocp_handle,
                undefined,
                0, // zero lpCompletionKey indicates notification for us
                &stub_overlapped,
            ) catch unreachable;
        }

        pub fn poll(self: *Reactor, notified: *bool, timeout_ms: u64) Task.List {
            var entries: [128]os.windows.OVERLAPPED_ENTRY = undefined;
            const found = os.windows.GetQueuedCompletionStatusEx(
                self.iocp_handle, 
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

            var list = Task.List{};
            for (entries[0..found]) |entry| {
                if (entry.lpCompletionKey == 0) {
                    assert(!notified.*);
                    notified.* = true;
                    continue;
                }

                const overlapped = entry.lpOverlapped;
                const io_status_block = @ptrCast(*os.windows.IO_STATUS_BLOCK, overlapped);
                const completion = @fieldParentPtr(Completion, "io_status_block", io_status_block);

                const poll_info = &completion.afd_poll_info;
                const polled_handle = poll_info.NumberOfHandles == 1;
                const has_events = poll_info.Handles[0].Events & completion.events != 0;

                // Try to reschedule the completion if we didn't receive the right events.
                if (!polled_handle or !has_events) blk: {
                    self.schedule(completion.fd, completion.io_type, completion) catch break :blk;
                    continue;
                }

                // If io_status_block.u.Status == .CANCELLED then CancelIoEx(fd) was called
                // If io_status_block.u.Status != .SUCCESS then fd failed in an unexpected way (EPOLLERR).
                // Regardless, we schedule the task for execution since it can detect failure on I/O retry.
                list.push(&completion.task);
            }

            return batch;
        }
    };
};