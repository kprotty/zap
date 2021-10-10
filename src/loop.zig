const std = @import("std");
const Lock = std.Thread.Mutex;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const builtin = @import("builtin");
const target = builtin.target;
const single_threaded = builtin.single_threaded;

const Loop = @This();

workers: []Worker,
net_poller: NetPoller,
pool: ThreadPool,
idle: WorkerStack = .{},
injecting: Atomic(usize) = Atomic(usize).init(0),
searching: Atomic(usize) = Atomic(usize).init(0),

fn schedule(self: *Loop, task: *Task) void {
    const list = List.from(task);
    const thread = Thread.current orelse return self.inject(list);

    const worker = thread.worker orelse @panic("schedule on thread without worker");
    worker.queue.push(list);
    self.notify();
}

fn inject(self: *Loop, list: List) void {
    const injecting = self.injecting.fetchAdd(1, .Monotonic);
    const random_worker = &self.workers[injecting % self.workers.len];

    random_worker.queue.inject(list);
    std.atomic.fence(.SeqCst);
    self.notify();
} 

fn notify(self: *Loop) void {
    return self.wake(false);
}

fn wake(self: *Loop, use_caller: bool) void {
    if (!self.idle.poppable())
        return;

    if (self.searching.load(.Monotonic) > 0)
        return;

    if (self.searching.compareAndSwap(0, 1, .SeqCst, .Monotonic)) |_|
        return;

    if (self.idle.pop()) |worker| {
        self.pool.spawn(worker, use_caller) catch self.idle.push(worker);
    }

    const searching = self.searching.fetchSub(1, .Monotonic);
    assert(searching > 0);
}

fn shutdown(self: *Loop) void {

}

const Task = struct {
    next: ?*Task = null,
    frame: ?anyframe = null,
};

const List = struct {
    head: ?*Task = null,
    tail: ?*Task = null,

    fn from(task: *Task) List {
        task.next = null;
        return .{ .head = task, .tail = task };
    }

    fn push(self: *List, list: List) void {
        const prev = if (self.tail) |tail| &tail.next else &self.head;
        prev.* = list.head orelse return;
        self.tail = list.tail;
    }

    fn pop(self: *List) ?*Task {
        const task = self.head orelse return null;
        self.head = task.next;
        if (self.head == null) self.tail = null;
        return task;
    }
};

const Worker = struct {
    next: ?*Worker = null,
    queue: Queue = .{},
};

const WorkerStack = struct {
    lock: Lock = .{},
    stack: Atomic(?*Worker) = Atomic(?*Worker).init(null),

    fn push(self: *WorkerStack, worker: *Worker) void {
        const held = self.lock.acquire();
        defer held.release();

        worker.next = self.stack.loadUnchecked();
        self.stack.store(worker, .Monotonic);
    }
    
    fn poppable(self: *WorkerStack) bool {
        return self.stack.load(.Monotonic) != null;
    }

    fn pop(self: *WorkerStack) ?*Worker {
        if (!self.poppable())
            return null;

        const held = self.lock.acquire();
        defer held.release();

        const worker = self.stack.loadUnchecked() orelse return null;
        self.stack.store(worker.next, .Monotonic);
        return worker;
    }
};

const Queue = struct {
    buffer: Buffer = .{},
    injector: Injector = .{},

    fn inject(self: *Queue, list: List) void {
        self.injector.push(list);
    }

    fn push(self: *Queue, list: List) void {
        const head = list.head orelse return;
        const tail = list.tail orelse unreachable;

        if (head == tail) {
            self.buffer.push(head, &self.injector);
        } else {
            self.injector.push(list);
        }
    }

    fn consumable(self: *const Queue) bool {
        return self.injector.consumable() or self.buffer.consumable();
    }

    fn pop(self: *Queue) ?*Task {
        return self.buffer.pop() orelse self.buffer.consume(&self.injector) catch null;
    }

    fn steal(self: *Queue, target: *Queue) error{Empty, Contended}!*Task {
        return self.buffer.consume(&target.injector) catch |err| {
            return self.buffer.steal(&target.buffer) orelse return err;
        };
    }
};

const Buffer = struct {
    head: Atomic(usize) = Atomic(usize).init(0),
    tail: Atomic(usize) = Atomic(usize).init(0),
    array: [256]Atomic(?*Task) = [_]Atomic(?*Task){Atomic(?*Task).init(null)} ** 256,

    fn write(self: *Buffer, index: usize, task: *Task) void {
        const slot = &self.array[index % self.array.len];
        slot.store(task, .Unordered);
    }

    fn read(self: *Buffer, index: usize) *Task {
        const slot = &self.array[index % self.array.len];
        return slot.load(.Unordered) orelse unreachable;
    }

    fn push(self: *Buffer, _list: List, injector: *Injector) void {
        var list = _list;
        var head = self.head.load(.Monotonic);
        var tail = self.tail.loadUnchecked();

        while (true) {
            const size = tail -% head;
            assert(size <= self.array.len);

            var available = self.array.len - size;
            if (available > 0) {
                while (available > 0) : (available -= 1) {
                    const task = list.pop() orelse break;
                    self.write(tail, task);
                    tail +%= 1;
                }

                self.tail.store(tail, .Release);
                self.injector.push(list);
                return;
            }

            var migrate = size / 2;
            head = self.head.tryCompareAndSwap(
                head,
                head +% migrate,
                .Acquire,
                .Monotonic,
            ) orelse {
                var overflowed = List{};
                while (migrate > 0) : (migrate -= 1) {
                    const task = self.read(head);
                    overflowed.push(List.from(task));
                    head +%= 1;
                }

                overflowed.push(list);
                self.injector.push(overflowed);
                return;
            };
        }
    }

    fn pop(self: *Buffer) ?*Task {
        const head = self.head.fetchSub(1, .Acquire);
        const tail = self.tail.loadUnchecked();

        const size = tail -% head;
        assert(size <= self.array.len);

        if (size > 0) {
            return self.read(head);
        }

        self.head.store(head, .Monotonic);
        return null;
    }

    fn consumable(self: *const Buffer) bool {
        const head = self.head.load(.Acquire);
        const tail = self.tail.load(.Acquire);
        return head != tail;
    }

    fn consume(self: *Buffer, injector: *Injector) error{Empty, Contended}!*Task {
        var consumer = try injector.consume();
        defer consumer.release();
        const consumed = consumer.pop() orelse return error.Empty;

        const head = self.head.load(.Monotonic);
        const tail = self.tail.loadUnchecked();

        const size = tail -% head;
        assert(size <= self.array.len);

        var new_tail = task;
        var available = self.array.len - size;
        while (available > 0) : (available -= 1) {
            const task = consumer.pop() orelse break;
            self.write(new_tail, task);
            new_tail +%= 1;
        }

        if (new_tail != tail)
            self.tail.store(new_tail, .Release);
        return consumed;
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
            if (buffer_size == @as(usize, 0) -% 1)
                return null;

            const buffer_steal = buffer_size - (buffer_size / 2);
            if (buffer_steal > buffer.array.len / 2)
                continue;

            const head = self.head.load(.Unordered);
            const tail = self.tail.loadUnchecked();
            assert(head == tail);

            var i: usize = 0;
            while (i < buffer_steal) : (i += 1) {
                const task = buffer.read(buffer_head +% i);
                self.write(tail +% i, task);
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
                return self.read(new_tail);
            };
        }
    }
};

const Injector = struct {
    head: Atomic(?*Task) = Atomic(?*Task).init(null),
    tail: Atomic(?*Task) = Atomic(?*Task).init(null),
    stub: Task = .{},

    fn next(task: *Task) *Atomic(?*Task) {
        return @ptrCast(*Atomic(?*Task), &task.next);
    }

    fn push(self: *Injector, list: List) void {
        const head = list.head orelse return;
        const tail = list.tail orelse unreachable;
        assert(tail.next == null);

        const prev = self.tail.swap(tail, .AcqRel) orelse &self.stub;
        next(prev).store(head, .Release);
    }

    fn consumable(self: *const Injector) bool {
        const tail = self.tail.load(.Monotonic) orelse &self.stub;
        if (tail == &self.stub)
            return false;

        return self.head.load(.Monotonic) != &self.stub;
    }

    fn consume(self: *Injector) error{Empty, Contended}!Consumer {
        const tail = self.tail.load(.Monotonic) orelse &self.stub;
        if (tail == &self.stub) 
            return error.Empty;

        const head = self.head.swap(&self.stub, .Acquire);
        if (head == &self.stub)
            return error.Contended;

        return Consumer{
            .injector = self,
            .head = head,
        };
    }

    const Consumer = struct {
        injector: *Injector,
        head: *Task,

        fn pop(self: *Consumer) ?*Task {
            var head = self.head;
            if (head == &self.injector.stub)
                head = next(head).load(.Acquire) orelse return null;

            if (next(head).load(.Acquire)) |new_head| {
                self.head = new_head;
                return head;
            }

            const tail = self.injector.tail.load(.Monotonic) orelse unreachable;
            if (head == tail)
                self.injector.push(List.from(&self.injector.stub))
            
            self.head = next(head).load(.Acquire) orelse return null;
            return head;
        }

        fn release(self: Consumer) void {
            var head: ?*Task = self.head;
            if (self.head == &self.injector.stub)
                head = null;

            assert(self.injector.head.load(.Unordered) == &self.injector.stub);
            self.injector.head.store(head, .Release);
        }
    };
};

const Thread = struct {
    loop: *Loop,
    worker: ?*Worker,
    tick: u32,
    xorshift: u32,
    searching: bool,

    threadlocal var current: ?*Thread = null;

    fn run(thread_pool: *ThreadPool, worker: *Worker) void {
        var self = Thread{
            .loop = @fieldParentPtr(Loop, "thread_pool", thread_pool),
            .worker = worker,
            .tick = 0,
            .xorshift = @truncate(u32, @ptrToInt(worker)) | 1,
            .searching = true,
        };

        current = &self;
        defer thread_pool.complete();

        while (self.poll()) |task| {
            if (self.searching) {
                const searching = self.loop.searching.fetchSub(1, .SeqCst);
                assert(searching > 0);

                self.searching = false;
                if (searching == 1) {
                    self.loop.notify();
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

            if (self.tick % (worker.queue.buffer.array.len / 2) == 0) blk: {
                return worker.queue.steal(&worker.queue) catch break :blk;
            }

            if (worker.queue.pop()) |task| {
                return task;
            }

            if (!self.searching) blk: {
                var searching = loop.searching.load(.Monotonic);
                if (2 * searching >= loop.workers.len) 
                    break :blk;

                searching = loop.searching.fetchAdd(1, .SeqCst);
                assert(searching < loop.workers.len);
                self.searching = true;
            }

            if (self.searching) {
                if (self.pollSearch(worker)) |task|
                    return task;
            }

            loop.idle.push(worker);
            self.worker = null;
            
            if (self.searching) {
                var searching = loop.searching.fetchSub(1, .SeqCst);
                assert(searching > 0);
                self.searching = false;

                if (searching == 1 and self.pollable()) blk: {
                    self.worker = self.loop.idle.pop() orelse break :blk;

                    const searching = loop.searching.fetchAdd(1, .Monotonic);
                    assert(searching < loop.workers.len);

                    self.searching = true;
                    continue;
                }
            }

            if (loop.net_poller.poll()) |*list| blk: {
                const task = list.pop() orelse break :blk;

                if (self.loop.idle.pop()) |new_worker| {
                    self.worker = new_worker;
                    new_worker.queue.push(list);

                    const searching = loop.searching.fetchAdd(1, .Monotonic);
                    assert(searching < loop.workers.len);

                    self.searching = true;
                    return task;
                }

                list.push(List.from(task));
                loop.inject(list);
            }

            self.worker = loop.pool.wait() catch return null;
            self.searching = true;
        }
    }
    
    fn pollable(self: *Thread) bool {
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
        self.xorshift ^= self.xorshift << 13;
        self.xorshift ^= self.xorshift >> 17;
        self.xorshift ^= self.xorshift << 7;

        var was_contended = false;
        var i = self.loop.workers.len;
        var steal_index = self.xorshift % self.loop.workers.len;
        
        while (i > 0) : (i -= 1) {
            const target_worker = &self.loop.workers[steal_index];
            return worker.queue.steal(&target_worker.queue) catch |err| switch (err) {
                was_contended = was_contended || err == error.Contended;
                steal_index = (steal_index + 1) % self.loop.workers.len;
                continue;
            };
        }

        if (was_contended) return error.Contended;
        return error.Empty;
    }
};

const ThreadPool = struct {
    lock: Lock = .{},
    joiner: ?*Signal = null,
    running: bool = true,
    idle: ?*Waiter = null,
    spawned: usize = 0,
    max_spawn: usize,
    stack_size: u32,

    const Waiter = struct {
        next: ?*Waiter = null,
        signal: Signal = .{},
        worker: ?*Worker = null,
    };

    const Signal = struct {
        futex: Atomic(u32) = Atomic(u32).init(0),

        fn wait(self: *Signal) void {
            while (self.futex.load(.Acquire) == 0)
                std.Thread.Futex.wait(&self.futex, 0, null) catch unreachable;
        }

        fn notify(self: *Signal) void {
            self.futex.store(1, .Release);
            std.Thread.Futex.wake(&self.futex);
        }
    };

    const SpawnError = std.Thread.SpawnError || error{Shutdown};

    fn spawn(self: *ThreadPool, worker: *Worker, use_caller: bool) SpawnError!void {
        const held = self.lock.acquire();

        if (!self.running) {
            held.release();
            return error.Shutdown;
        }

        if (self.idle) |waiter| {
            self.idle = waiter.next;
            held.release();
            waiter.worker = worker;
            return waiter.signal.notify();
        }

        if (self.spawned == self.max_spawn) {
            held.release();
            return error.ThreadQuotaExceeded;
        }

        self.spawned += 1;
        held.release();

        if (single_threaded or use_caller) {
            return Thread.run(self, worker);
        }
        
        const thread = std.Thread.spawn(
            .{ .stack_size = self.stack_size },
            Thread.run,
            .{ self, worker },
        ) catch |err| {
            self.complete();
            return err;
        };
        thread.detach();
    }

    fn wait(self: *ThreadPool) error{Shutdown}!*Worker {
        const held = self.lock.acquire();

        if (!self.running) {
            held.release();
            return error.Shutdown;
        }

        var waiter = Waiter{ .next = self.idle };
        self.idle = &waiter;
        held.release();

        waiter.signal.wait();
        return waiter.worker orelse error.Shutdown;
    }

    fn shutdown(self: *ThreadPool) void {
        var waiters: ?*Waiter = null;
        defer while (waiters) |waiter| {
            waiters = waiter.next;
            waiter.worker = null;
            waiter.signal.notify();
        };

        const held = self.lock.acquire();
        defer held.release();

        self.running = false;
        std.mem.swap(?*Waiter, &self.idle, &waiters);
    }

    fn complete(self: *ThreadPool) void {
        var joiner: ?*Signal = null;
        defer if (joiner) |signal|
            signal.notify();

        const held = self.lock.acquire();
        defer held.release();

        assert(self.spawned > 0);
        self.spawned -= 1;

        if (self.spawned == 0) {
            std.mem.swap(?*Signal, &self.joiner, &joiner); 
        }
    }

    fn join(self: *ThreadPool) void {
        var joiner: ?Signal = null;
        defer if (joiner) |*signal|
            sigla.wait();

        const held = self.lock.acquire();
        defer held.release();

        if (self.spawned > 0) {
            joiner = Signal{};
            if (joiner) |*signal| self.joiner = signal;
        }
    }
};

const NetPoller = struct {
    
    
};

const NetPoll = switch (target.os.tag) {
    .windows => Iocp,
    .linux => Epoll,
    else => Kqueue,
};

const Iocp = @compileError("TODO: Windows AFD + IO_STATUS_BLOCK per read/write");
const Kqueue = @compileError("TODO: EVFILT_USER for macos/freebsd, EVFILT_TIMER for openbsd");

const DelayQueue = struct {
    
};

const TimerWheel = struct {
    const wheel_bit = 6;
    const wheel_num = 6;
    const timeout_t = u64;

    const wheel_len = 1 << wheel_bit;
    const wheel_mask = wheel_len - 1;

    const wheel_timeout_max = (1 << (wheel_bit * wheel_num)) - 1;
    assert(wheel_timeout_max <= std.math.maxInt(timeout_t));

    const wheel_t = std.meta.Int(.unsigned, 1 << wheel_bit);
    const wheel_slot_t = std.math.Int(.unsigned, wheel_bit);
    const wheel_num_t = std.math.Log2Int(std.meta.Int(.unsigned, wheel_num));
    
    const Timeout = struct {
        expires: timeout_t,
        prev: ?*Timeout = null,
        next: ?*Timeout = null,
        tail: ?*Timeout = null,
        list: ?*TimeoutList = null,
    };

    const TimeoutList = struct {
        head: ?*Timeout = null,

        fn peek(self: TimeoutList) ?*Timeout {
            return self.head;
        }

        fn consume(self: *TimeoutList, list: *TimeoutList) void {
            assert(self != list);
            defer list.* = .{};
            
            const list_head = list.head orelse return;
            const list_tail = list_head.tail orelse unreachable;

            if (self.head) |head| {
                const tail = head.tail orelse unreachable;
                list_head.prev = tail;
                tail.next = list_head;
                head.tail = list_tail;
            } else {
                self.head = list_head;
            }
        }

        fn insert(self: *TimeoutList, timeout: *Timeout) void {
            assert(timeout.list == null);
            timeout.list = self;
            timeout.next = null;

            if (self.head) |head| {
                const tail = head.tail orelse unreachable;
                timeout.prev = tail;
                tail.next = timeout;
                head.tail = timeout;
            } else {
                timeout.prev = null;
                timeout.tail = timeout;
                self.head = timeout;
            }
        }

        fn remove(self: *TimeoutList, timeout: *Timeout) void {
            const list = timeout.list orelse unreachable;
            const head = self.head orelse unreachable;
            const tail = head.tail orelse unreachable;
            assert(list == self);

            if (timeout.prev) |prev| {
                prev.next = timeout.next;
                if (timeout.next) |next| {
                    next.prev = timeout.prev;
                } else {
                    assert(timeout == tail);
                    head.tail = prev;
                }
            } else {
                assert(timeout == head);
                self.head = timeout.next;
                if (self.head) |new_head| {
                    new_head.tail = timeout.tail;
                }
            }
        }
    };

    wheel: [wheel_num][wheel_len]TimeoutList = [_][wheel_len]TimeoutList{[_]TimeoutList{.{}} ** wheel_len} ** wheel_num,
    pending: [wheel_num]wheel_t = [_]wheel_t{0} ** wheel_num,
    current: timeout_t = 0,

    pub fn insert(self: *TimerWheel, timeout: *Timeout, ticks: timeout_t) void {
        assert(ticks != 0);
        timeout.* = .{ .expires = self.current + ticks };

        const wheel = blk: {
            const raw_fls = @bitSizeOf(timeout_t) - @clz(timeout_t, ticks);
            const fls = @intCast(std.math.Log2Int(timeout_t), raw_fls);
            break :blk @intCast(wheel_num_t, fls / wheel_bit);
        };

        const slot = blk: {
            const raw_wheel = @intCast(std.math.Log2Int(timeout_t), wheel);
            const diff = timeout.expires >> (raw_wheel * wheel_bit);
            const adjust = if (wheel != 0) @as(u1, 1) else 0;
            break :blk @intCast(wheel_slot_t, diff - adjust);
        };

        const list = &self.wheel[wheel][slot];
        const empty = list.peek() == null;
        list.insert(timeout);

        if (empty) {
            const mask = @as(wheel_t, 1) << slot;
            assert(self.pending[wheel] & mask == 0);
            self.pending[wheel] |= mask;
        }
    }

    pub fn remove(self: *TimerWheel, timeout: *Timeout) bool {
        const list = timeout.list orelse return false;
        list.remove(timeout);

        if (list.peek() == null) {
            const index = (@ptrToInt(list) - @ptrToInt(&self.wheel[0][0])) / @sizeOf(TimeoutList);
            const wheel = @intCast(wheel_num_t, index / wheel_len);
            const slot = @intCast(wheel_slot_t, index & wheel_len);

            const mask = @as(wheel_t, 1) << slot;
            assert(self.pending[wheel] & mask != 0);
            self.pending[wheel] &= ~mask;
        }
    }

    pub const Poll = struct {
        expired: TimeoutList = .{},
        next_expire: ?timeout_t = null,
    };

    pub fn poll(self: *TimerWheel, current: timeout_t) Poll {
        var polled = Poll{};
        var process = TimeoutList{};
        var elapsed = std.math.sub(timeout_t, current - self.current) catch return polled;
        
        for (self.pending) |*slot_mask, wheel| {
            const raw_wheel = @intCast(std.math.Log2Int(timeout_t), wheel);
            const offset = raw_wheel * wheel_bit;

            var slots = ~@as(wheel_t, 0);
            if ((elapsed >> offset) <= wheel_mask) {
                const eo = @intCast(wheel_slot_t, elapsed >> offset);
                const eo_mask = (@as(wheel_t, 1) << eo) - 1;

                const o_slot = @intCast(wheel_slot_t, self.current >> offset);
                slots = std.math.rotl(wheel_t, eo_mask, o_slot);

                const n_slot = @intCast(wheel_slot_t, current >> offset);
                const rotated = std.math.rotl(wheel_t, eo_mask, n_slot);
                slots |= std.math.rotr(wheel_t, rotated, eo);
                slots |= @as(wheel_t, 1) << n_slot;
            }

            while (true) {
                const mask = slots & slot_mask.* != 0;
                if (mask == 0)
                    break;

                const slot = @ctz(wheel_t, mask);
                slot_mask.* &= ~(@as(wheel_t, 1) << slot);

                const list = &self.wheel[wheel][slot];
                process.consume(list);
                assert(list.peek() == null);
            }

            elapsed = switch (slots & 1) {
                0 => break,
                1 => std.math.max(elapsed, wheel_len) << offset,
                else => unreachable,
            };
        }

        self.current = current;
        while (process.peek()) |timeout| {
            const list = timeout.list orelse unreachable;
            list.remove(timeout);

            if (std.math.sub(timeout_t, timeout.expires, current)) |ticks| {
                self.insert(timeout, ticks);
            } else |_| {
                polled.expired.insert(timeout);
            }
        }

        return polled;
    }
};