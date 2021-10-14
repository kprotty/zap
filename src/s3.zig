const std = @import("std");
const os = std.os;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;
const Allocator = std.mem.Allocator;

const builtin = @import("builtin");
const target = builtin.target;
const single_threaded = builtin.single_threaded;

pub const Loop = @This();

workers: []Worker,
net_poller: NetPoller,
thread_pool: Thread.Pool,
idle: Atomic(usize) = Atomic(usize).init(0),
injecting: Atomic(usize) = Atomic(usize).init(0),
searching: Atomic(usize) = Atomic(usize).init(0),

pub var instance: ?*Loop = null;

pub fn run(comptime asyncFn: anytype, args: anytype) !@typeInfo(@TypeOf(asyncFn)).Fn.return_type.? {
    const Args = @TypeOf(args);
    const Result = @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
    const Entry = struct {
        fn call(task: *Task, fn_args: Args) Result {
            suspend { 
                task.* = Task.init(@frame());
            }
            defer Loop.instance.?.shutdown();
            return @call(.{}, asyncFn, fn_args);
        }
    };

    var task: Task = undefined;
    var frame = async Entry.call(&task, args);
    try runTask(&task);
    return nosuspend await frame;
}

fn runTask(task: *Task) !void {
    const num_cpus = switch (single_threaded) {
        true => 1,
        else => std.math.max(1, std.Thread.getCpuCount() catch 1), 
    };

    if (num_cpus == 1) {
        var workers: [1]Worker = undefined;
        return runTaskWithWorkers(task, &workers);
    }

    var win_heap = if (target.os.tag == .windows) std.heap.HeapAllocator.init() else {};
    const allocator = if (builtin.link_libc)
        std.heap.c_allocator
    else if (target.os.tag == .windows)
        &win_heap.allocator
    else
        std.heap.page_allocator;

    const workers = try allocator.alloc(Worker, num_cpus);
    defer allocator.free(workers);
    return runTaskWithWorkers(task, workers);
}

fn runTaskWithWorkers(task: *Task, workers: []Worker) !void {
    var self = Loop{
        .workers = workers,
        .net_poller = try NetPoller.init(),
        .thread_pool = Thread.Pool{ .max_threads = workers.len },
    };

    for (workers) |*worker| {
        worker.* = .{};
        self.putIdleWorker(worker);
    }

    defer {
        self.shutdown();
        self.thread_pool.join();
        self.net_poller.deinit();
    }

    assert(instance == null);
    instance = &self;
    defer instance = null;

    self.schedule(task);
}

pub fn reschedule(self: *Loop) void {
    var task = Task.init(@frame());
    suspend { self.schedule(&task); }
}

pub fn yield(self: *Loop) void {
    var task = Task.init(@frame());
    suspend { self.inject(Task.List.from(&task)); }
}

pub fn schedule(self: *Loop, task: *Task) void {
    const list = Task.List.from(task);
    const thread = Thread.current orelse return self.inject(list);

    const worker = thread.worker orelse unreachable;
    worker.queue.push(task);
    self.notify();
}

fn inject(self: *Loop, list: Task.List) void {
    const rand_worker_index = self.injecting.fetchAdd(1, .Monotonic) % self.workers.len;
    const rand_worker = &self.workers[rand_worker_index];

    rand_worker.queue.inject(list);
    std.atomic.fence(.SeqCst);
    self.notify();
}

fn notify(self: *Loop) void {
    if (self.peekIdleWorker() == null)
        return;
    
    if (self.searching.load(.Monotonic) > 0)
        return;

    if (self.searching.compareAndSwap(0, 1, .Acquire, .Monotonic)) |_|
        return;

    if (self.getIdleWorker()) |worker| blk: {
        return self.thread_pool.spawn(worker) catch {
            self.putIdleWorker(worker);
            break :blk;
        };
    }

    const searching = self.searching.fetchSub(1, .Monotonic);
    assert(searching > 0);
}

fn shutdown(self: *Loop) void {
    self.net_poller.notify();
    self.thread_pool.shutdown();
}

const Worker = struct {
    next: Atomic(Idle.Count) = Atomic(Idle.Count).init(0),
    queue: Task.Queue = .{},
};

const Idle = packed struct {
    index: Count = 0,
    aba: Count = 0,
    const Count = std.meta.Int(.unsigned, @bitSizeOf(usize) / 2);
};

fn putIdleWorker(self: *Loop, worker: *Worker) void {
    const index = (@ptrToInt(worker) - @ptrToInt(self.workers.ptr)) / @sizeOf(Worker);
    const worker_index = @intCast(Idle.Count, index);

    var idle = @bitCast(Idle, self.idle.load(.Monotonic));
    while (true) {
        var new_idle = idle;
        new_idle.aba +%= 1;
        new_idle.index = worker_index + 1;
        worker.next.store(idle.index, .Monotonic);

        idle = @bitCast(Idle, self.idle.tryCompareAndSwap(
            @bitCast(usize, idle),
            @bitCast(usize, new_idle),
            .Release,
            .Monotonic,
        ) orelse return);
    }
}

fn peekIdleWorker(self: *Loop) ?*Worker {
    const idle = @bitCast(Idle, self.idle.load(.Acquire));
    const worker_index = std.math.sub(usize, idle.index, 1) catch return null;
    return &self.workers[worker_index];
}

fn getIdleWorker(self: *Loop) ?*Worker {
    var idle = @bitCast(Idle, self.idle.load(.Acquire));
    while (true) {
        const worker_index = std.math.sub(usize, idle.index, 1) catch return null;
        const worker = &self.workers[worker_index];

        var new_idle = idle;
        new_idle.index = worker.next.load(.Monotonic);

        idle = @bitCast(Idle, self.idle.tryCompareAndSwap(
            @bitCast(usize, idle),
            @bitCast(usize, new_idle),
            .Acquire,
            .Acquire,
        ) orelse return worker);
    }
}

const Thread = struct {
    loop: *Loop,
    worker: ?*Worker,
    searching: bool,
    xorshift: u32,
    tick: u32,

    threadlocal var current: ?*Thread = null;

    fn run(loop: *Loop, worker: *Worker) void {
        var self = Thread{
            .loop = loop,
            .worker = worker,
            .searching = true,
            .xorshift = @truncate(u32, @ptrToInt(worker)) | 1,
            .tick = 0,
        };

        current = &self;
        defer current = null;

        while (self.poll()) |task| {
            if (self.searching) {
                const searching = loop.searching.fetchSub(1, .Monotonic);
                assert(searching > 0);
                self.searching = false;

                if (searching == 1) {
                    loop.notify();
                }
            }

            self.tick +%= 1;
            const frame = task.frame orelse unreachable;
            resume frame;
        }
    }

    fn poll(self: *Thread) ?*Task {
        while (true) {
            const worker = self.worker orelse return null;
            const loop = self.loop;

            const be_fair = self.tick % 128 == 0;
            if (worker.queue.pop(be_fair)) |task| {
                return task;
            }

            if (!self.searching) blk: {
                var searching = loop.searching.load(.Monotonic);
                if (2 * searching >= loop.workers.len) {
                    break :blk;
                }

                searching = loop.searching.fetchAdd(1, .SeqCst);
                assert(searching < loop.workers.len);
                self.searching = true;
            }

            if (self.searching) {
                if (self.pollSearch(worker)) |task| {
                    return task;
                }
            }

            loop.putIdleWorker(worker);
            self.worker = null;

            if (self.searching) {
                var searching = loop.searching.fetchSub(1, .SeqCst);
                assert(searching > 0);
                self.searching = false;
                
                if (searching == 1 and self.pollConsumable()) blk: {
                    self.worker = loop.getIdleWorker() orelse break :blk;

                    searching = loop.searching.fetchAdd(1, .SeqCst);
                    assert(searching <= loop.workers.len);
                    self.searching = true;
                    continue;
                }
            }

            if (loop.net_poller.poll()) |polled| blk: {
                var list = polled;
                if (list.len == 0) 
                    break :blk;

                self.worker = loop.getIdleWorker() orelse {
                    loop.inject(list);
                    break :blk;
                };

                const searching = loop.searching.fetchAdd(1, .SeqCst);
                assert(searching <= loop.workers.len);
                self.searching = true;

                const task = list.pop() orelse unreachable;
                self.worker.?.queue.inject(list);
                return task;
            }

            self.worker = loop.thread_pool.wait() catch return null;
            self.searching = true;
        }
    }

    fn pollConsumable(self: *Thread) bool {
        for (self.loop.workers) |*worker| {
            if (worker.queue.consumable())
                return true;
        }
        return false;
    }

    fn pollSearch(self: *Thread, worker: *Worker) ?*Task {
        var attempts: usize = 32;
        while (true) {
            return self.pollSteal(worker) catch |err| switch (err) {
                error.Empty => return null,
                error.Contended => {
                    attempts = std.math.sub(usize, attempts, 1) catch return null;
                    std.atomic.spinLoopHint();
                    continue;
                },
            };
        }
    }

    fn pollSteal(self: *Thread, worker: *Worker) error{Empty, Contended}!*Task {
        var xs = self.xorshift;
        xs ^= xs << 13;
        xs ^= xs >> 17;
        xs ^= xs << 7;
        self.xorshift = xs;

        var was_contended = false;
        var i: usize = self.loop.workers.len;
        var target_index = xs % self.loop.workers.len;
        
        while (i > 0) : (i -= 1) {
            const target_worker = &self.loop.workers[target_index];
            return worker.queue.steal(&target_worker.queue) catch |err| {
                if (err == error.Contended) 
                    was_contended = true;
                target_index = (target_index + 1) % self.loop.workers.len;
                continue;
            };
        }

        if (was_contended) return error.Contended;
        return error.Empty;
    }

    const Pool = struct {
        lock: Lock = .{},
        idle: IdleQueue = .{},
        joiner: ?*Event = null,
        running: bool = true,
        spawned: usize = 0,
        max_threads: usize,

        const Lock = struct {
            state: Atomic(u32) = Atomic(u32).init(0),

            fn acquire(self: *Lock) void {
                if (self.state.swap(1, .Acquire) == 0)
                    return;
                while (self.state.swap(2, .Acquire) != 0)
                    std.Thread.Futex.wait(&self.state, 2, null) catch unreachable;
            }

            fn release(self: *Lock) void {
                if (self.state.swap(0, .Release) == 2)
                    std.Thread.Futex.wake(&self.state, 1);
            }
        };

        const Event = struct {
            state: Atomic(u32) = Atomic(u32).init(0),

            fn wait(self: *Event) void {
                while (self.state.load(.Acquire) == 0)
                    std.Thread.Futex.wait(&self.state, 0, null) catch unreachable;
            }

            fn wake(self: *Event) void {
                self.state.store(1, .Release);
                std.Thread.Futex.wake(&self.state, 1);
            }
        };

        const IdleQueue = std.TailQueue(struct {
            event: Event = .{},
            worker: ?*Worker = null,

            pub fn wait(self: *@This()) ?*Worker {
                self.event.wait();
                return self.worker;
            }

            pub fn wake(self: *@This(), worker: ?*Worker) void {
                self.worker = worker;
                self.event.wake();
            }
        });

        fn spawn(self: *Pool, worker: *Worker) !void {
            self.lock.acquire();

            if (!self.running) {
                self.lock.release();
                return error.Shutdown;
            }

            if (self.idle.popFirst()) |waiter| {
                self.lock.release();
                return waiter.data.wake(worker);
            }

            if (self.spawned == self.max_threads) {
                self.lock.release();
                return error.ThreadQuotaExceeded;
            }

            const use_caller_thread = self.spawned == 0;
            self.spawned += 1;
            self.lock.release();

            if (use_caller_thread) 
                return self.run(worker);

            if (single_threaded)
                @panic("tried to spawn thread in single_threaded");

            errdefer self.finish();
            const thread = try std.Thread.spawn(.{}, Pool.run, .{self, worker});
            thread.detach();
        }

        fn run(self: *Pool, worker: *Worker) void {
            defer self.finish();
            const loop = @fieldParentPtr(Loop, "thread_pool", self);
            return Thread.run(loop, worker);
        }

        fn wait(self: *Pool) error{Shutdown}!*Worker {
            var waiter: IdleQueue.Node = undefined;
            {
                self.lock.acquire();
                defer self.lock.release();

                if (!self.running)
                    return error.Shutdown;

                waiter = .{ .data = .{} };
                self.idle.prepend(&waiter);
            }
            return waiter.data.wait() orelse error.Shutdown;
        }

        fn shutdown(self: *Pool) void {
            var idle = IdleQueue{};
            defer while (idle.popFirst()) |waiter|
                waiter.data.wake(null);
            
            self.lock.acquire();
            defer self.lock.release();

            self.running = false;
            std.mem.swap(IdleQueue, &self.idle, &idle);
        }

        fn finish(self: *Pool) void {
            var joiner: ?*Event = null;
            defer if (joiner) |join_event|
                join_event.wake();

            self.lock.acquire();
            defer self.lock.release();

            self.spawned -= 1;
            if (self.spawned == 0)
                std.mem.swap(?*Event, &self.joiner, &joiner);
        }

        fn join(self: *Pool) void {
            var joiner: ?Event = null;
            defer if (joiner) |*join_event|
                join_event.wait();

            self.lock.acquire();
            defer self.lock.release();

            if (self.spawned > 0) {
                joiner = Event{};
                if (joiner) |*join_event| 
                    self.joiner = join_event;
            }
        }
    };
};

pub const Task = struct {
    next: ?*Task = null,
    frame: ?anyframe = null,

    pub fn init(frame: anyframe) Task {
        return .{ .frame = frame };
    }

    const List = struct {
        len: usize = 0,
        head: ?*Task = null,
        tail: ?*Task = null,

        fn from(task: *Task) List {
            task.next = null;
            return .{
                .len = 1,
                .head = task,
                .tail = task,
            };
        }

        fn push(self: *List, list: List) void {
            if (list.len == 0) {
                return;
            }

            if (self.len == 0) self.tail = list.tail;
            list.tail.?.next = self.head;
            self.head = list.head;
            self.len += list.len;
        }

        fn pop(self: *List) ?*Task {
            self.len = std.math.sub(usize, self.len, 1) catch return null;
         
            if (self.len == 0) self.tail = null;
            const task = self.head orelse unreachable;
            self.head = task.next;
            return task;
        }
    };

    const Queue = struct {
        buffer: Buffer = .{},
        injector: Injector = .{},

        fn push(self: *Queue, task: *Task) void {
            self.buffer.push(task, &self.injector);
        }

        fn inject(self: *Queue, list: List) void {
            self.injector.push(list);
        }

        fn consumable(self: *const Queue) bool {
            return self.injector.consumable() or self.buffer.consumable();
        }

        fn pop(self: *Queue, be_fair: bool) ?*Task {
            return switch (be_fair) {
                true => self.buffer.consume(&self.injector) catch self.buffer.pop() orelse null,
                else => self.buffer.pop() orelse self.buffer.consume(&self.injector) catch null,
            };
        }

        fn steal(self: *Queue, queue: *Queue) error{Empty, Contended}!*Task {
            return self.buffer.consume(&queue.injector) catch |consume_error| {
                return self.buffer.steal(&queue.buffer) orelse consume_error;
            };
        }
    };

    const Injector = struct {
        pushed: Atomic(?*Task) = Atomic(?*Task).init(null),
        popped: Atomic(?*Task) = Atomic(?*Task).init(null),
        
        fn push(self: *Injector, list: List) void {
            if (list.len == 0) {
                return;
            }

            var pushed = self.pushed.load(.Monotonic);
            while (true) {
                list.tail.?.next = pushed;
                pushed = self.pushed.tryCompareAndSwap(
                    pushed,
                    list.head,
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

        fn push(self: *Buffer, task: *Task, injector: *Injector) void {
            var head = self.head.load(.Monotonic);
            const tail = self.tail.loadUnchecked();

            while (true) {
                const size = tail -% head;
                assert(size <= capacity);

                if (size < capacity) {
                    self.array[tail % capacity].store(task, .Unordered);
                    self.tail.store(tail +% 1, .Release);
                    return;
                }

                var migrate = size / 2;
                head = self.head.tryCompareAndSwap(
                    head,
                    head +% migrate,
                    .Acquire,
                    .Monotonic,
                ) orelse {
                    var list = Task.List{};
                    while (migrate > 0) : (migrate -= 1) {
                        const migrated = self.array[head % capacity].loadUnchecked() orelse unreachable;
                        list.push(Task.List.from(migrated));
                        head +%= 1;
                    }

                    list.push(Task.List.from(task));
                    injector.push(list);
                    return;
                };
            }
        }

        fn pop(self: *Buffer) ?*Task {
            var head = self.head.load(.Monotonic);
            const tail = self.tail.loadUnchecked();

            while (true) {
                const size = tail -% head;
                assert(size <= self.array.len);

                if (size == 0) {
                    return null;
                }

                head = self.head.tryCompareAndSwap(
                    head,
                    head +% 1,
                    .Acquire,
                    .Monotonic,
                ) orelse return self.array[head % capacity].loadUnchecked();
            }
        }

        fn consumable(self: *const Buffer) bool {
            const head = self.head.load(.Acquire);
            const tail = self.tail.load(.Acquire);
            return (tail != head) and (tail != head -% 1);
        }

        fn steal(self: *Buffer, buffer: *Buffer) ?*Task {
            if (self == buffer)
                return null;

            while (true) : (std.atomic.spinLoopHint()) {
                const buffer_head = buffer.head.load(.Acquire);
                const buffer_tail = buffer.tail.load(.Acquire);

                const buffer_size = buffer_tail -% buffer_head;
                if (buffer_size == 0)
                    return null;

                const buffer_steal = buffer_size - (buffer_size / 2);
                if (buffer_steal > capacity / 2)
                    continue;

                const head = self.head.load(.Unordered);
                const tail = self.tail.loadUnchecked();
                assert(head == tail);

                var i: usize = 0;
                while (i < buffer_steal) : (i += 1) {
                    const task = buffer.array[(buffer_head +% i) % capacity].load(.Unordered);
                    self.array[(tail +% i) % capacity].store(task, .Unordered);
                }

                _ = buffer.head.compareAndSwap(
                    buffer_head,
                    buffer_head +% buffer_steal,
                    .AcqRel,
                    .Monotonic,
                ) orelse {
                    const new_tail = tail +% (buffer_steal - 1);
                    if (tail != new_tail)
                        self.tail.store(new_tail, .Release);
                    return self.array[new_tail % capacity].loadUnchecked();
                };
            }
        }

        fn consume(self: *Buffer, injector: *Injector) error{Empty, Contended}!*Task {
            var consumer = try injector.consume();
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
};

const IoType = enum {
    read,
    write,
};

pub fn waitForReadable(self: *Loop, fd: os.fd_t) void {
    return self.waitFor(fd, .read);
}

pub fn waitForWritable(self: *Loop, fd: os.fd_t) void {
    return self.waitFor(fd, .write);
}

fn waitFor(self: *Loop, fd: os.fd_t, io_type: IoType) void {
    var completion: Reactor.Completion = undefined;
    completion.task = Task.init(@frame());

    self.net_poller.begin();
    suspend {
        self.net_poller.reactor.schedule(fd, io_type, &completion) catch {
            self.net_poller.finish(1);
            resume @frame();
        };
    }
}

const NetPoller = struct {
    notified: Atomic(bool) = Atomic(bool).init(false),
    polling: Atomic(bool) = Atomic(bool).init(false),
    pending: Atomic(usize) = Atomic(usize).init(0),
    reactor: Reactor,

    fn init() !NetPoller {
        return NetPoller{ .reactor = try Reactor.init() };
    }

    fn deinit(self: *NetPoller) void {
        self.reactor.deinit();
        assert(self.pending.load(.Monotonic) == 0);
        assert(!self.polling.load(.Monotonic));
    }

    fn begin(self: *NetPoller) void {
        const pending = self.pending.fetchAdd(1, .SeqCst);
        assert(pending < std.math.maxInt(usize));
    }

    fn finish(self: *NetPoller, count: usize) void {
        const pending = self.pending.fetchSub(count, .Monotonic);
        assert(pending >= count);
    }

    fn acquire(self: *NetPoller, flag: *Atomic(bool)) bool {
        if (self.pending.load(.Monotonic) == 0) return false;
        if (flag.load(.Monotonic)) return false;
        return !flag.swap(true, .Acquire);
    }

    fn notify(self: *NetPoller) void {
        if (self.acquire(&self.notified)) {
            self.reactor.notify();
        }
    }

    fn poll(self: *NetPoller) ?Task.List {
        if (!self.acquire(&self.polling)) return null;
        defer self.polling.store(false, .Release);

        var notified = false;
        var list = self.reactor.poll(&notified);

        if (list.len > 0) {
            self.finish(list.len);
        }

        if (notified) {
            assert(self.notified.load(.Monotonic));
            self.notified.store(false, .Release);
        }

        return list;
    }
};

const Reactor = switch (target.os.tag) {
    .windows => WindowsReactor,
    .linux => LinuxReactor,
    else => BSDReactor,
};

const LinuxReactor = struct {
    epoll_fd: os.fd_t,
    event_fd: os.fd_t,

    pub fn init() !Reactor {
        var self: Reactor = undefined;

        self.epoll_fd = try os.epoll_create1(os.linux.EPOLL.CLOEXEC);
        errdefer os.close(self.epoll_fd);

        self.event_fd = try os.eventfd(0, os.linux.EFD.CLOEXEC | os.linux.EFD.NONBLOCK);
        errdefer os.close(self.event_fd);

        try self.register(
            os.linux.EPOLL.CTL_ADD,
            self.event_fd,
            os.linux.EPOLL.IN, // level-triggered, readable
            0 // zero epoll_event.data.ptr for event_fd
        );

        return self;
    }

    fn deinit(self: Reactor) void {
        os.close(self.event_fd);
        os.close(self.epoll_fd);
    }

    const Completion = struct {
        task: Task,
    };

    fn schedule(self: Reactor, fd: os.fd_t, io_type: IoType, completion: *Completion) !void {
        const ptr = @ptrToInt(&completion.task);
        const events = os.linux.EPOLL.ONESHOT | @as(u32, switch (io_type) {
            .read => os.linux.EPOLL.IN | os.linux.EPOLL.RDHUP,
            .write => os.linux.EPOLL.OUT,
        });

        return self.register(os.linux.EPOLL.CTL_MOD, fd, events, ptr) catch |err| switch (err) {
            error.FileDescriptorNotRegistered => self.register(os.linux.EPOLL.CTL_ADD, fd, events, ptr),
            else => err,
        };
    }

    fn register(self: Reactor, op: u32, fd: os.fd_t, events: u32, user_data: usize) !void {
        var event = os.linux.epoll_event{
            .data = .{ .ptr = user_data },
            .events = events | os.linux.EPOLL.ERR | os.linux.EPOLL.HUP,
        };
        try os.epoll_ctl(self.epoll_fd, op, fd, &event);
    }

    fn notify(self: Reactor) void {
        var value: u64 = 0;
        const wrote = os.write(self.event_fd, std.mem.asBytes(&value)) catch unreachable;
        assert(wrote == @sizeOf(u64));
    }

    fn poll(self: Reactor, notified: *bool) Task.List {
        var events: [128]os.linux.epoll_event = undefined;
        const found = os.epoll_wait(self.epoll_fd, &events, -1);

        var list = Task.List{};
        for (events[0..found]) |ev| {
            list.push(Task.List.from(@intToPtr(?*Task, ev.data.ptr) orelse {
                var value: u64 = 0;
                const read = os.read(self.event_fd, std.mem.asBytes(&value)) catch unreachable;
                assert(read == @sizeOf(u64));
                
                assert(!notified.*);
                notified.* = true;
                continue;
            }));
        }

        return list;
    }
};

const BSDReactor = struct {
    kqueue_fd: os.fd_t,

    const notify_info = switch (target.os.tag) {
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
        var self = Reactor{ .kqueue_fd = try os.kqueue() };
        errdefer os.close(self.kqueue_fd);

        try self.kevent(.{
            .ident = 0, // zero-ident for notify event,
            .filter = notify_info.filter,
            .flags = os.system.EV_ADD | os.system.EV_CLEAR | os.system.EV_DISABLE,
            .fflags = 0, // fflags unused for notify_info.filter
            .udata = 0, // zero-udata for notify event
        });

        return self;
    }

    fn deinit(self: Reactor) void {
        os.close(self.kqueue_fd);
    }

    const Completion = struct {
        task: Task,
    };

    fn schedule(self: Reactor, fd: os.fd_t, io_type: IoType, completion: *Completion) !void {
        try self.kevent(.{
            .ident = @intCast(usize, fd),
            .filter = @as(i32, switch (io_type) {
                .read => os.system.EVFILT_READ,
                .write => os.system.EVFILT_WRITE,
            }),
            .flags = os.system.EV_ADD | os.system.EV_ENABLE | os.system.EV_ONESHOT,
            .fflags = 0, // fflags usused for read/write events
            .udata = @ptrToInt(&completion.task),
        });
    }

    fn notify(self: Reactor) void {
        self.kevent(.{
            .ident = 0, // zero-ident for notify event
            .filter = notify_info.filter,
            .flags = os.system.EV_ENABLE,
            .fflags = notify_info.fflags,
            .udata = 0, // zero-udata for notify event
        }) catch unreachable;
    }

    fn kevent(self: Reactor, info: anytype) !void {
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

    fn poll(self: Reactor, notified: *bool) Task.List {
        var events: [64]os.Kevent = undefined;
        const found = os.kevent(
            self.kqueue_fd,
            &[0]os.Kevent{},
            &events,
            null,
        ) catch unreachable;

        var list = Task.List{};
        for (events[0..found]) |ev| {
            list.push(Task.List.from(@intToPtr(?*Task, ev.udata) orelse {
                assert(!notified.*);
                notified.* = true;
                continue;
            }));
        }

        return list;
    }
};

const WindowsReactor = struct {
    afd: os.windows.HANDLE,
    iocp: os.windows.HANDLE,

    fn init() !Reactor {
        const ascii_name = "\\Device\\Afd\\Zig";
        comptime var afd_name = std.mem.zeroes([ascii_name.len + 1]os.windows.WCHAR);
        inline for (ascii_name) |char, i| {
            afd_name[i] = @as(os.windows.WCHAR, char);
        }

        const afd_len = @intCast(os.windows.USHORT, afd_name.len) * @sizeOf(os.windows.WCHAR);
        var afd_string = os.windows.UNICODE_STRING{
            .Length = afd_len,
            .MaximumLength = afd_len,
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
            .OBJECT_NAME_INVALID => unreachable,
            else => |status| return os.windows.unexpectedStatus(status),
        }
        errdefer os.windows.CloseHandle(afd_handle);
        
        const iocp_handle = try os.windows.CreateIoCompletionPort(os.windows.INVALID_HANDLE_VALUE, null, 0, 0);
        errdefer os.windows.CloseHandle(iocp_handle);

        const iocp_afd_handle = try os.windows.CreateIoCompletionPort(afd_handle, iocp_handle, 1, 0);
        assert(iocp_afd_handle == iocp_handle);

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

    fn schedule(self: Reactor, fd: os.fd_t, io_type: IoType, completion: *Completion) !void {
        const afd_events = @as(os.windows.ULONG, switch (io_type) {
            .read => AFD_POLL_RECEIVE | AFD_POLL_ACCEPT | AFD_POLL_DISCONNECT,
            .write => AFD_POLL_SEND,
        });

        completion.afd_poll_info = .{
            .Timeout = std.math.maxInt(os.windows.LARGE_INTEGER),
            .NumberOfHandles = 1,
            .Exclusive = os.windows.FALSE,
            .Handles = [_]AFD_POLL_HANDLE_INFO{.{
                .Handle = fd,
                .Status = .SUCCESS,
                .Events = AFD_POLL_ABORT | AFD_POLL_LOCAL_CLOSE | AFD_POLL_CONNECT_FAIL | afd_events,
            }},
        };

        completion.io_status_block = .{
            .u = .{ .Status = .PENDING },
            .Information = 0,
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

    fn poll(self: Reactor, notified: *bool) Task.List {
        var entries: [128]os.windows.OVERLAPPED_ENTRY = undefined;
        const found = os.windows.GetQueuedCompletionStatusEx(
            self.iocp, 
            &entries,
            os.windows.INFINITE,
            false, // not alertable wait
        ) catch |err| switch (err) {
            error.Aborted => unreachable,
            error.Cancelled => unreachable,
            error.EOF => unreachable,
            error.Timeout => unreachable,
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

            assert(io_status_block.u.Status != .CANCELLED);
            list.push(Task.List.from(&completion.task));
        }

        return list;
    }
};

pub const net = struct {
    pub const Address = std.net.Address;

    pub fn tcpConnectToHost(allocator: *Allocator, name: []const u8, port: u16) !Stream {
        const list = try std.net.getAddressList(allocator, name, port);
        defer list.deinit();

        if (list.addrs.len == 0) {
            return error.UnknownHostName;
        }

        for (list.addrs) |addr| {
            return tcpConnectToAddress(addr) catch |err| switch (err) {
                error.ConnectionRefused => continue,
                else => return err,
            };
        }
        return os.ConnectError.ConnectionRefused;
    }

    pub fn tcpConnectToAddress(address: Address) !Stream {
        const socket = try Socket.init(address.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);
        errdefer socket.close();

        try socket.connect(address);

        return Stream{ .socket = socket };
    }

    pub const Stream = struct {
        socket: Socket,

        pub fn deinit(self: *Stream) void {
            self.socket.deinit();
        }

        pub fn close(self: Stream) void {
            self.socket.close();
        }

        pub const ReadError = os.ReadError;
        pub const WriteError = os.WriteError;

        pub const Reader = std.io.Reader(Stream, ReadError, read);
        pub const Writer = std.io.Writer(Stream, WriteError, write);

        pub fn reader(self: Stream) Reader {
            return .{ .context = self };
        }

        pub fn writer(self: Stream) Writer {
            return .{ .context = self };
        }

        pub fn read(self: Stream, buffer: []u8) ReadError!usize {
            return self.socket.recvfrom(buffer, null) catch |err| switch (err) {
                error.ConnectionRefused => unreachable,
                error.SocketNotBound => unreachable,
                error.MessageTooBig => unreachable,
                error.NetworkSubsystemFailed => unreachable,
                error.SocketNotConnected => unreachable,
                else => |e| e,
            };
        }

        pub fn write(self: Stream, buffer: []const u8) WriteError!usize {
            return self.socket.sendto(buffer, null) catch |err| switch (err) {
                error.FastOpenAlreadyInProgress => unreachable,
                error.MessageTooBig => unreachable,
                error.FileDescriptorNotASocket => unreachable,
                error.NetworkUnreachable => unreachable,
                error.NetworkSubsystemFailed => unreachable,
                error.AddressFamilyNotSupported => unreachable,
                error.SymLinkLoop => unreachable,
                error.NameTooLong => unreachable,
                error.FileNotFound => unreachable,
                error.SocketNotConnected => unreachable,
                error.AddressNotAvailable => unreachable,
                error.NotDir => unreachable,
                else => |e| e,
            };
        }
    };

    pub const StreamServer = struct {
        socket: ?Socket,
        options: Options,
        address: Address,

        pub const Options = struct {
            kernel_backlog: u31 = 128,
            reuse_address: bool = false,
        };

        pub fn init(options: Options) StreamServer {
            return .{
                .socket = null,
                .options = options,
                .address = undefined,
            };
        }

        pub fn deinit(self: *StreamServer) void {
            self.close();
            self.* = undefined;
        }

        pub fn close(self: *StreamServer) void {
            if (self.socket) |socket| {
                socket.close();
                self.socket = null;
                self.address = undefined;
            }
        }

        pub fn listen(self: *StreamServer, address: Address) !void {
            const proto = if (address.any.family == os.AF.UNIX) @as(u32, 0) else os.IPPROTO.TCP;
            const socket = try Socket.init(address.any.family, os.SOCK.STREAM, proto);
            errdefer socket.close();

            const sock_fd = socket.getHandle();
            self.socket = socket;
            errdefer self.socket = null;

            if (self.options.reuse_address) {
                try os.setsockopt(
                    sock_fd,
                    os.SOL.SOCKET,
                    os.SO.REUSEADDR,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            }

            self.address = address;
            var socklen = address.getOsSockLen();
            try os.bind(sock_fd, &self.address.any, socklen);
            try os.listen(sock_fd, self.options.kernel_backlog);
            try os.getsockname(sock_fd, &self.address.any, &socklen);            
        }

        pub const AcceptError = error{
            ConnectionAborted,
            /// The per-process limit on the number of open file descriptors has been reached.
            ProcessFdQuotaExceeded,
            /// The system-wide limit on the total number of open files has been reached.
            SystemFdQuotaExceeded,
            /// Not enough free memory.  This often means that the memory allocation  is  limited
            /// by the socket buffer limits, not by the system memory.
            SystemResources,
            /// Socket is not listening for new connections.
            SocketNotListening,
            ProtocolFailure,
            /// Firewall rules forbid connection.
            BlockedByFirewall,
            FileDescriptorNotASocket,
            ConnectionResetByPeer,
            NetworkSubsystemFailed,
            OperationNotSupported,
        } || os.UnexpectedError;

        pub const Connection = struct {
            stream: Stream,
            address: Address,
        };

        pub fn accept(self: *StreamServer) AcceptError!Connection {
            var address: Address = undefined;
            const socket = self.socket.?.accept(&address) catch |err| switch (err) {
                error.WouldBlock => unreachable,
                else => |e| return e,
            };

            return Connection{
                .stream = Stream{ .socket = socket },
                .address = address,
            };
        }
    };

    pub const Socket = struct {
        fd: os.socket_t,
        read_tick: u8 = 0,

        pub fn init(domain: u32, sock_type: u32, protocol: u32) !Socket {
            const fd = try os.socket(domain, sock_type | os.SOCK.NONBLOCK | os.SOCK.CLOEXEC, protocol);
            errdefer os.closeSocket(fd);
            return Socket.fromFd(fd);
        }

        fn fromFd(fd: os.socket_t) !Socket {
            if (comptime target.os.tag.isDarwin()) {
                os.setsockopt(
                    fd,
                    os.SOL.SOCKET,
                    os.SO.NOSIGPIPE,
                    &std.mem.toBytes(@as(c_int, 1)),
                ) catch return error.NetworkSubsystemFailed;
            }
            return Socket{ .fd = fd };
        }

        pub fn deinit(self: *Socket) void {
            self.close();
            self.fd = switch (target.os.tag) {
                .windows => os.windows.INVALID_HANDLE_VALUE,
                else => -1,
            };
        }

        pub fn getHandle(self: Socket) os.socket_t {
            return self.fd;
        }

        pub fn close(self: Socket) void {
            os.closeSocket(self.fd);
        }

        pub fn connect(self: Socket, addr: Address) !void {
            System.connect(self.fd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
                else => return err,
                error.WouldBlock => {
                    Loop.instance.?.waitForWritable(self.fd);
                    return os.getsockoptError(self.fd);
                },
            };
        }

        pub fn accept(self: Socket, addr: *Address) os.AcceptError!Socket {
            var addr_len: os.socklen_t = @sizeOf(Address);
            while (true) {
                const fd = os.accept(self.fd, &addr.any, &addr_len, os.SOCK.CLOEXEC) catch |err| switch (err) {
                    else => return err,
                    error.WouldBlock => {
                        Loop.instance.?.waitForReadable(self.fd);
                        continue;
                    },
                };
                return Socket.fromFd(fd);
            }
        }

        const io_flags = switch (target.os.tag) {
            .macos, .ios, .watchos, .tvos => 0,
            .windows => 0,
            else => os.MSG.NOSIGNAL,
        };

        pub fn sendto(self: Socket, buf: []const u8, addr: ?Address) os.SendToError!usize {
            while (true) {
                const adr = if (addr) |*a| &a.any else null;
                const adr_len: os.socklen_t = if (addr) |_| @sizeOf(Address) else 0;

                return System.sendto(self.fd, buf, io_flags, adr, adr_len) catch |err| switch (err) {
                    else => return err,
                    error.WouldBlock => {
                        Loop.instance.?.waitForWritable(self.fd);
                        continue;
                    },
                };
            }
        }

        pub fn recvfrom(self: Socket, buf: []u8, addr: ?*Address) os.RecvFromError!usize {
            while (true) {
                var len: os.socklen_t = @sizeOf(Address);
                const adr = if (addr) |a| &a.any else null;
                const adr_len = if (addr) |_| &len else null;

                return System.recvfrom(self.fd, buf, io_flags, adr, adr_len) catch |err| switch (err) {
                    else => return err,
                    error.WouldBlock => {
                        Loop.instance.?.waitForReadable(self.fd);
                        continue;
                    },
                };
            }
        }

        // stdlib has a bunch of stuff not working for windows
        const System = switch (target.os.tag) {
            .windows => WindowsSystem,
            else => StdSystem,
        };

        const StdSystem = struct {
            const connect = os.connect;
            const sendto = os.sendto;
            const recvfrom = os.recvfrom;
        };

        const WindowsSystem = struct {
            fn connect(sock: os.socket_t, sock_addr: *os.sockaddr, len: os.socklen_t) !void {
                const rc = os.ws2_32.connect(sock, sock_addr, @intCast(i32, len));
                if (rc == 0) return;
                switch (os.windows.ws2_32.WSAGetLastError()) {
                    .WSAEADDRINUSE => return error.AddressInUse,
                    .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                    .WSAECONNREFUSED => return error.ConnectionRefused,
                    .WSAECONNRESET => return error.ConnectionResetByPeer,
                    .WSAETIMEDOUT => return error.ConnectionTimedOut,
                    .WSAEHOSTUNREACH,
                    .WSAENETUNREACH,
                    => return error.NetworkUnreachable,
                    .WSAEFAULT => unreachable,
                    .WSAEINVAL => unreachable,
                    .WSAEISCONN => unreachable,
                    .WSAENOTSOCK => unreachable,
                    .WSAEWOULDBLOCK => error.WouldBlock,
                    .WSAEACCES => unreachable,
                    .WSAENOBUFS => return error.SystemResources,
                    .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                    else => |err| return os.windows.unexpectedWSAError(err),
                }
            }

            const win = struct {
                extern "ws2_32" fn sendto(
                    s: os.socket_t,
                    buf: [*]const u8,
                    len: i32,
                    flags: i32,
                    to: ?*const os.sockaddr,
                    tolen: i32,
                ) callconv(os.windows.WINAPI) i32;
            };

            fn sendto(sockfd: os.socket_t, buf: []const u8, flags: u32, dest_addr: ?*const os.sockaddr, addrlen: os.socklen_t) !usize {
                while (true) {
                    const rc = win.sendto(
                        sockfd, 
                        buf.ptr, 
                        @intCast(i32, buf.len), 
                        @bitCast(i32, flags), 
                        dest_addr, 
                        @bitCast(i32, addrlen),
                    );
                    if (rc == os.windows.ws2_32.SOCKET_ERROR) {
                        switch (os.windows.ws2_32.WSAGetLastError()) {
                            .WSAEACCES => return error.AccessDenied,
                            .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                            .WSAECONNRESET => return error.ConnectionResetByPeer,
                            .WSAEMSGSIZE => return error.MessageTooBig,
                            .WSAENOBUFS => return error.SystemResources,
                            .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                            .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                            .WSAEDESTADDRREQ => unreachable, // A destination address is required.
                            .WSAEFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                            .WSAEHOSTUNREACH => return error.NetworkUnreachable,
                            // TODO: WSAEINPROGRESS, WSAEINTR
                            .WSAEINVAL => unreachable,
                            .WSAENETDOWN => return error.NetworkSubsystemFailed,
                            .WSAENETRESET => return error.ConnectionResetByPeer,
                            .WSAENETUNREACH => return error.NetworkUnreachable,
                            .WSAENOTCONN => return error.SocketNotConnected,
                            .WSAESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                            .WSAEWOULDBLOCK => return error.WouldBlock,
                            .WSANOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                            else => |err| return os.windows.unexpectedWSAError(err),
                        }
                    } else {
                        return @intCast(usize, rc);
                    }
                }
            }

            fn recvfrom(sockfd: os.socket_t, buf: []u8, flags: u32, src_addr: ?*os.sockaddr, addrlen: ?*os.socklen_t) !usize {
                while (true) {
                    const rc = os.windows.ws2_32.recvfrom(
                        sockfd, 
                        buf.ptr, 
                        @intCast(i32, buf.len), 
                        @bitCast(i32, flags), 
                        src_addr, 
                        @ptrCast(?*i32, addrlen),
                    );
                    if (rc == os.windows.ws2_32.SOCKET_ERROR) {
                        switch (os.windows.ws2_32.WSAGetLastError()) {
                            .WSANOTINITIALISED => unreachable,
                            .WSAECONNRESET => return error.ConnectionResetByPeer,
                            .WSAEINVAL => return error.SocketNotBound,
                            .WSAEMSGSIZE => return error.MessageTooBig,
                            .WSAENETDOWN => return error.NetworkSubsystemFailed,
                            .WSAENOTCONN => return error.SocketNotConnected,
                            .WSAEWOULDBLOCK => return error.WouldBlock,
                            // TODO: handle more errors
                            else => |err| return os.windows.unexpectedWSAError(err),
                        }
                    } else {
                        return @intCast(usize, rc);
                    }
                }
            }
        };
    };
};