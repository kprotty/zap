const std = @import("std");
const system = @import("system.zig");

const assert = std.debug.assert;

pub const Builder = struct {
    max_blocking_threads: usize = 64,
    max_blocking_stack_size: usize = 64 * 1024,
    max_threads: usize = std.math.maxInt(usize),
    max_stack_size: usize = switch (@typeInfo(usize).Int.bits) {
        32 => 1 * 1024 * 1024,
        64 => 4 * 1024 * 1024,
        else => @compileError("Architecture not supported"),
    },

    pub const RunError = error{
        OutOfNodeMemory,
    };

    pub fn run(
        self: Builder,
        runnable: *Runnable,
    ) RunError!void {
        const topology = system.Node.getTopology();
        assert(topology.len > 0);

        var start_node: ?*Node = null;
        var start_index = blk: {
            var rng: RandomGenerator = undefined;
            rng.init(@ptrToInt(runnable) ^ @ptrToInt(topology.ptr));
            defer rng.deinit();
            break :blk rng.next() % topology.len;
        };

        var nodes = Link.Queue{};
        defer {
            while (true) {
                const node = Node.fromLink(nodes.pop() orelse break);
                const node_memory = blk: {
                    const begin_ptr = @ptrToInt(node);
                    const end_ptr = @ptrToInt(node.slots_ptr + node.slots_len);
                    const memory_ptr = @intToPtr([*]align(std.mem.page_size) u8, begin_ptr);
                    const memory_len = end_ptr - begin_ptr;
                    break :blk memory_ptr[0..memory_len];
                };
                node.numa_node.free(std.mem.page_size, node_memory);
            }
        }

        var remaining_core_threads = std.math.max(1, self.max_threads);
        var remaining_blocking_threads = std.math.max(1, self.max_blocking_threads);
        for (topology) |*numa_node, index| {
            const core_threads = std.math.min(numa_node.affinity.getCount(), remaining_core_threads);
            const blocking_threads = std.math.max(1, self.max_blocking_threads) / topology.len;
            remaining_core_threads -= core_threads;
            remaining_blocking_threads -= blocking_threads;

            const node = blk: {
                var bytes: usize = 0;
                const alignment = @alignOf(Node);
                const node_offset = bytes;
                bytes += @sizeOf(Node);

                bytes = std.mem.alignForward(bytes, @alignOf(Thread.Slot));
                const slots_offset = bytes;
                const num_slots = core_threads + blocking_threads;
                bytes += @sizeOf(Thread.Slot) * num_slots;

                const memory = numa_node.alloc(alignment, bytes) orelse return RunError.OutOfNodeMemory;
                const node = @intToPtr(*Node, @ptrToInt(&memory[node_offset]));
                const slots_ptr = @intToPtr([*]Thread.Slot, @ptrToInt(&memory[slots_offset]));
                node.init(
                    slots_ptr[0..num_slots],
                    numa_node,
                    self.max_stack_size,
                    self.max_blocking_stack_size,
                    core_threads,
                ) catch unreachable;
                break :blk node;
            };

            nodes.push(.Back, node.getLink());
            if (index == start_index and start_node == null)
                start_node = node;
            if (remaining_core_threads == 0 or remaining_blocking_threads == 0) {
                if (start_node == null)
                    start_node = node;
                break;
            }
        }

        const main_node = start_node.?;
        Scheduler.run(nodes, main_node, runnable);
    }
};

pub const Scheduler = struct {
    running_nodes: usize align(CACHE_LINE),
    active_nodes: usize align(CACHE_LINE),
    stop_event: system.AutoResetEvent,
    start_node: *Node,
    num_nodes: usize,

    pub fn run(
        nodes: Link.Queue,
        noalias start_node: *Node,
        noalias runnable: *Runnable,
    ) void {
        const nodes_head = Node.fromLink(nodes.head orelse return);
        const nodes_tail = Node.fromLink(nodes.tail.?);

        var self = Scheduler{
            .running_nodes = 0,
            .active_nodes = 0,
            .stop_event = undefined,
            .start_node = start_node,
            .num_nodes = nodes.len,
        };

        var node = nodes_head;
        var has_start_node = false;
        while (true) {
            if (node == start_node)
                has_start_node = true;
            node.scheduler = &self;
            node.num_links = nodes.len;
            node = Node.fromLink(node.link.next orelse break);
        }

        if (has_start_node) {
            self.stop_event.init();
            nodes_tail.link.next = &nodes_head.link;
            start_node.core_pool.schedule(Link.Queue.fromLink(runnable.getLink()));
            self.stop_event.wait();
            self.stop_event.deinit();
        }

        assert(@atomicLoad(usize, &self.running_nodes, .Monotonic) == 0);
        assert(@atomicLoad(usize, &self.active_nodes, .Monotonic) == 0);
        nodes_tail.link.next = null;
        node = nodes_head;
        while (true) {
            node.deinit();
            node = Node.fromLink(node.link.next orelse break);
        }
    }

    fn shutdown(self: *Scheduler) void {
        var node = self.start_node;
        var num_nodes = self.num_nodes;
        while (num_nodes != 0) : (num_nodes -= 1) {
            node.core_pool.shutdown();
            node.blocking_pool.shutdown();
            node = Node.fromLink(node.link.next orelse break);
        }
    }
};

pub const Node = extern struct {
    running_threads: usize align(CACHE_LINE),
    active_threads: usize align(CACHE_LINE),
    core_pool: Thread.Pool,
    blocking_pool: Thread.Pool,
    slots_ptr: [*]Thread.Slot,
    slots_len: usize,
    scheduler: *Scheduler,
    numa_node: *system.Node,
    link: Link,
    num_links: usize,

    pub const Error = error{
        InvalidSlotCount,
        InvalidBlockingSlotCount,
    };

    pub fn init(
        self: *Node,
        slots: []Thread.Slot,
        numa_node: *system.Node,
        stack_size: usize,
        blocking_stack_size: usize,
        num_core_threads: usize,
    ) Error!void {
        if (slots.len < 2)
            return Error.InvalidSlotCount;
        if (num_core_threads == 0 or (slots.len - num_core_threads < 1))
            return Error.InvalidBlockingSlotCount;
        
        self.running_threads = 0;
        self.active_threads = 0;
        self.slots_ptr = slots.ptr;
        self.slots_len = slots.len;
        self.numa_node = numa_node;
        self.core_pool.init(self, false, num_core_threads, stack_size);
        self.blocking_pool.init(self, true, num_core_threads, blocking_stack_size);
    }

    fn deinit(self: *Node) void {
        assert(@atomicLoad(usize, &self.running_threads, .Monotonic) == 0);
        assert(@atomicLoad(usize, &self.active_threads, .Monotonic) == 0);
        self.core_pool.deinit();
        self.blocking_pool.deinit();
    }

    fn getLink(self: *Node) *Link {
        return &self.link;
    }

    fn fromLink(link: *Link) *Node {
        return @fieldParentPtr(Node, "link", link);
    }

    fn getSlots(self: Node) []Thread.Slot {
        return self.slots_ptr[0..self.slots_len];
    }
};

pub const Thread = extern struct {
    pub const Slot = extern struct {
        next: usize,
        data: usize,
    };

    pub const Pool = extern struct {
        idle_queue: ABAProtectedAtomicUsize align(CACHE_LINE),
        is_polling_run_queue: Guard,
        run_queue: Link.Queue.Unbounded,
        slots_offset: usize,
        stack_size: usize,
        node_ptr: usize,

        const IDLE_EMPTY = 0x0;
        const IDLE_STOPPED = 0x1;
        const IDLE_NOTIFIED = 0x2;

        fn init(
            self: *Pool,
            node: *Node,
            is_blocking: bool,
            slots_offset: usize,
            max_stack_size: usize,
        ) void {
            self.idle_queue = ABAProtectedAtomicUsize.init(IDLE_EMPTY);
            self.is_polling_run_queue.init();
            self.run_queue.init();
            self.slots_offset = slots_offset;
            self.stack_size = max_stack_size;
            self.node_ptr = @ptrToInt(node) | @boolToInt(is_blocking);

            for (self.getSlots()) |*slot| {
                slot.* = Slot{
                    .next = self.idle_queue.get(),
                    .data = 0x0,
                };
                self.idle_queue = ABAProtectedAtomicUsize.init(@ptrToInt(slot));
            }
        }

        fn deinit(self: *Pool) void {
            defer self.* = undefined;

            assert(self.idle_queue.load(.Monotonic).get() == IDLE_STOPPED);
            self.is_polling_run_queue.deinit();
            self.run_queue.deinit();

            for (self.getSlots()) |*slot| {
                const slot_data = @atomicLoad(usize, &slot.data, .Acquire);
                if (slot_data & 1 != 0) {
                    if (@intToPtr(?system.Thread.Handle, slot_data & ~@as(usize, 1))) |thread_handle|
                        system.Thread.join(thread_handle);
                } else {
                    assert(slot_data == 0);
                }
            }
        }

        fn isBlockingPool(self: Pool) bool {
            return @truncate(u1, self.node_ptr) != 0;
        }

        fn getNode(self: Pool) *Node {
            return @intToPtr(*Node, self.node_ptr & ~@as(usize, 1));
        }

        fn getSlots(self: Pool) []Slot {
            const slots = self.getNode().getSlots();
            if (self.isBlockingPool())
                return slots[self.slots_offset..];
            return slots[0..self.slots_offset];
        }

        fn getIterator(self: *Pool) Iter {
            return Iter.init(self);
        }

        const Iter = struct {
            node: *Node,
            remaining: usize,
            is_blocking: bool,

            fn init(pool: *Pool) Iter {
                const node = pool.getNode();
                return Iter{
                    .node = node,
                    .remaining = node.num_links,
                    .is_blocking = pool.isBlockingPool(),
                };
            }

            fn next(self: *Iter) ?*Pool {
                if (self.remaining == 0)
                    return null;
                self.remaining -= 1;

                const node = self.node;
                self.node = Node.fromLink(node.link.next.?);
                return switch (self.is_blocking) {
                    true => &node.blocking_pool,
                    else => &node.core_pool,
                };
            }
        };

        fn getSlotIterator(self: *Pool, rng_seed: usize) SlotIter {
            return SlotIter.init(self, rng_seed);
        }

        const SlotIter = struct {
            slots: []Slot,
            index: usize,
            remaining: usize,

            fn init(pool: *Pool, rng_seed: usize) SlotIter {
                const slots = pool.getSlots();
                return SlotIter{
                    .slots = slots,
                    .index = rng_seed % slots.len,
                    .remaining = slots.len,
                };
            }

            fn next(self: *SlotIter) ?*Slot {
                if (self.remaining == 0)
                    return null;
                self.remaining -= 1;

                const slot = &self.slots[self.index];
                self.index +%= 1;
                if (self.index >= self.slots.len)
                    self.index = 0;
                return slot;
            }
        };

        fn schedule(self: *Pool, queue: Link.Queue) void {
            self.run_queue.push(queue);
            self.resumeThread();
        }

        fn resumeThread(self: *Pool) void {
            var pool_iter = self.getIterator();
            while (pool_iter.next()) |pool| {
                if (pool.tryResumeThread())
                    return;
            }
        }

        fn tryResumeThread(self: *Pool) bool {
            var idle_queue = self.idle_queue.load(.Acquire);

            while (true) {
                switch (idle_queue.get()) {
                    IDLE_STOPPED, IDLE_NOTIFIED => {
                        return false;
                    },
                    IDLE_EMPTY => {
                        idle_queue = self.idle_queue.compareExchange(
                            idle_queue,
                            IDLE_NOTIFIED,
                            .Acquire,
                            .Acquire,
                        ) orelse return true;
                    },
                    else => |slot_ptr| {
                        const slot = @intToPtr(*Slot, slot_ptr);
                        idle_queue = self.idle_queue.compareExchange(
                            idle_queue,
                            slot.next,
                            .Acquire,
                            .Acquire,
                        ) orelse return self.tryWakeThread(slot);
                    },
                }
            }
        }

        fn tryWakeThread(
            noalias self: *Pool,
            noalias slot: *Slot,
        ) bool {
            const node = self.getNode();
            const scheduler = node.scheduler;
            if (@atomicRmw(usize, &node.active_threads, .Add, 1, .Monotonic) == 0)
                _ = @atomicRmw(usize, &scheduler.active_nodes, .Add, 1, .Monotonic);

            const slot_data = @atomicLoad(usize, &slot.data, .Acquire);
            assert(slot_data & 1 == 0);
            if (@intToPtr(?*Thread, slot_data)) |thread| {
                assert(!thread.is_stopped);
                thread.event.notify();
                return true;
            }

            var is_main_thread = false;
            if (@atomicRmw(usize, &node.running_threads, .Add, 1, .Monotonic) == 0)
                is_main_thread = @atomicRmw(usize, &scheduler.running_nodes, .Add, 1, .Monotonic) == 0;
    
            slot.next = @ptrToInt(self);
            if (is_main_thread) {
                Thread.run(slot);
                return true;
            }

            if (system.Thread.spawn(
                node.numa_node,
                self.stack_size,
                slot,
                Thread.run,
            )) |thread_handle| {
                return true;
            }

            assert(!is_main_thread);
            if (@atomicRmw(usize, &node.active_threads, .Sub, 1, .Monotonic) == 1)
                assert(@atomicRmw(usize, &scheduler.active_nodes, .Sub, 1, .Monotonic) > 1);
            if (@atomicRmw(usize, &node.running_threads, .Sub, 1, .Monotonic) == 1)
                assert(@atomicRmw(usize, &scheduler.running_nodes, .Sub, 1, .Monotonic) > 1);

            var idle_queue = self.idle_queue.load(.Monotonic);
            while (true) {
                switch (idle_queue.get()) {
                    IDLE_STOPPED => unreachable,
                    else => |slot_ptr| {
                        slot.next = slot_ptr;
                        idle_queue = self.idle_queue.compareExchange(
                            idle_queue,
                            @ptrToInt(slot),
                            .Release,
                            .Monotonic,
                        ) orelse return false;
                    }
                }
            }
        }

        fn trySuspendThread(
            noalias self: *Pool,
            noalias thread: *Thread,
        ) bool {
            const slot = thread.slot;
            var idle_queue = self.idle_queue.load(.Monotonic);

            while (true) {
                switch (idle_queue.get()) {
                    IDLE_STOPPED => return false,
                    IDLE_NOTIFIED => {
                        idle_queue = self.idle_queue.compareExchange(
                            idle_queue,
                            IDLE_EMPTY,
                            .Monotonic,
                            .Monotonic,
                        ) orelse return true;
                    },
                    else => |slot_ptr| {
                        slot.next = slot_ptr;
                        idle_queue = self.idle_queue.compareExchange(
                            idle_queue,
                            @ptrToInt(slot),
                            .Release,
                            .Monotonic,
                        ) orelse break;
                    },
                }
            }

            const node = self.getNode();
            if (@atomicRmw(usize, &node.active_threads, .Sub, 1, .Monotonic) == 1) {
                const scheduler = node.scheduler;
                if (@atomicRmw(usize, &scheduler.active_nodes, .Sub, 1, .Monotonic) == 1) {
                    scheduler.shutdown();
                    return false;
                }
            }


            thread.event.wait();
            return !thread.is_stopped;
        }

        fn shutdown(self: *Pool) void {
            const idle_queue_ptr = self.idle_queue.getDirectPtr();
            var idle_queue = @atomicRmw(usize, idle_queue_ptr, .Xchg, IDLE_STOPPED, .Acquire);

            while (true) {
                switch (idle_queue) {
                    IDLE_EMPTY, IDLE_STOPPED, IDLE_NOTIFIED => return,
                    else => |slot_ptr| {
                        const slot = @intToPtr(*Slot, slot_ptr);
                        idle_queue = slot.next;
                        const slot_data = @atomicLoad(usize, &slot.data, .Acquire);
                        assert(slot_data & 1 == 0);

                        if (@intToPtr(?*Thread, slot_data)) |thread| {
                            thread.is_stopped = true;
                            thread.event.notify();
                        }
                    }
                }
            }
        }
    };

    run_queue: Link.Queue.Bounded(256),
    rng_state: RandomGenerator,
    event: system.AutoResetEvent,
    is_stopped: bool,
    slot: *Slot,
    pool: *Pool,

    fn run(slot: *Slot) void {
        const pool = @intToPtr(*Pool, slot.next);
        const node = pool.getNode();
        const scheduler = node.scheduler;

        node.numa_node.affinity.bindCurrentThread();
        var self = Thread{
            .run_queue = undefined,
            .rng_state = undefined,
            .event = undefined,
            .is_stopped = false,
            .slot = slot,
            .pool = pool,
        };

        self.run_queue.init();
        self.rng_state.init(@ptrToInt(&self) ^ @ptrToInt(pool));
        self.event.init();
        @atomicStore(usize, &slot.data, @ptrToInt(&self), .Release);

        defer {
            const handle = system.Thread.getCurrentHandle();
            @atomicStore(usize, &slot.data, @ptrToInt(handle) | 1, .Release);
            self.run_queue.deinit();
            self.rng_state.deinit();
            self.event.deinit();
        }

        var iteration: usize = 0;
        const max_direct_yields = 8;
        while (true) {

            while (self.poll(pool, iteration)) |runnable_ptr| {
                iteration +%= 1;
                var next_runnable: ?*Runnable = runnable_ptr;
                for (@as([max_direct_yields]void, undefined)) |_| {
                    const runnable = next_runnable orelse break;
                    next_runnable = runnable.run(&self);
                }
                
                if (next_runnable) |runnable| {
                    self.schedule(.Local, Link.Queue.fromLink(runnable.getLink()));
                }
            }

            if (!pool.trySuspendThread(&self))
                break;
        }

        if (@atomicRmw(usize, &node.running_threads, .Sub, 1, .Monotonic) == 1) {
            if (@atomicRmw(usize, &scheduler.running_nodes, .Sub, 1, .Monotonic) == 1)
                scheduler.stop_event.notify();
        }
    }

    fn poll(
        noalias self: *Thread,
        noalias pool: *Pool,
        iteration: usize,
    ) ?*Runnable {
        if (iteration % 127 == 0) {
            if (self.pollOS(pool, false)) |runnable| {
                pool.resumeThread();
                return runnable;
            }
        }

        if (iteration % 61 == 0) {
            if (self.pollGlobal(pool)) |runnable| {
                pool.resumeThread();
                return runnable;
            }
        }

        if (iteration % 31 == 0) {
            if (self.pollLocal(.Back)) |runnable| {
                return runnable;
            }
        }

        if (self.pollLocal(.Front)) |runnable| {
            return runnable;
        }

        if (self.pollOS(pool, false)) |runnable| {
            pool.resumeThread();
            return runnable;
        }

        const stolen_runnable = blk: {
            const steal_attempts = 4;
            for (@as([steal_attempts]void, undefined)) |_| {
                const rng_seed = self.rng_state.next();

                var pool_iter = pool.getIterator();
                while (pool_iter.next()) |target_pool| {
                    if (self.pollGlobal(target_pool)) |runnable| {
                        break :blk runnable;
                    }

                    var slot_iter = pool.getSlotIterator(rng_seed);
                    while (slot_iter.next()) |slot| {
                        const slot_data = @atomicLoad(usize, &slot.data, .Acquire);
                        if (slot_data & 1 != 0)
                            continue;
                        const target_thread = @intToPtr(?*Thread, slot_data) orelse continue;
                        if (target_thread == self)
                            continue;
                        if (self.pollSteal(target_thread)) |runnable| {
                            break :blk runnable;
                        }
                    }
                }
            }
            
            break :blk self.pollOS(pool, true);
        };

        const runnable = stolen_runnable orelse return null;
        pool.resumeThread();
        return runnable;
    }

    fn pollLocal(
        noalias self: *Thread,
        side: Link.Queue.Side,
    ) ?*Runnable {
        const link = self.run_queue.pop(side);
        return Runnable.fromLink(link orelse return null);
    }

    fn pollGlobal(
        noalias self: *Thread,
        noalias pool: *Pool,
    ) ?*Runnable {
        if (!pool.is_polling_run_queue.tryAcquire())
            return null;
        defer pool.is_polling_run_queue.release();
        const link = self.run_queue.stealFromUnbounded(&pool.run_queue);
        return Runnable.fromLink(link orelse return null);
    }

    fn pollSteal(
        noalias self: *Thread,
        noalias target: *Thread,
    ) ?*Runnable {
        const link = self.run_queue.stealFromBounded(&target.run_queue);
        return Runnable.fromLink(link orelse return null);
    }

    fn pollOS(
        noalias self: *Thread,
        noalias pool: *Pool,
        can_block: bool,
    ) ?*Runnable {
        // TODO: IO and Timers
        return null;
    }

    pub fn schedule(
        self: *Thread,
        context: Runnable.ScheduleContext,
        batch: Link.Queue,
    ) void {
        const pool = self.pool;
        if (batch.len == 0)
            return;
        
        if (context == .Local and batch.len == 1) {
            const runnable = Runnable.fromLink(batch.head.?);
            const side = switch (runnable.getPriority()) {
                .Low => return pool.schedule(batch),
                .Normal => Link.Queue.Side.Back,
                .High => Link.Queue.Side.Front,
            };
            self.run_queue.push(side, &runnable.link, &pool.run_queue);
            pool.resumeThread();
            return;
        }

        pool.schedule(batch);
    }
};

pub const Runnable = extern struct {
    link: Link,
    state: usize,

    pub const Context = *Thread;
    pub const ScheduleContext = enum(u1) {
        Local = 0,
        Remote = 1,
    };

    pub const Callback = fn(
        noalias *Runnable,
        noalias Context,
    ) callconv(.C) ?*Runnable;

    pub const Priority = enum(u2) {
        Low = 0,
        Normal = 1,
        High = 2,
    };

    pub fn init(priority: Priority, callback: Callback) Runnable {
        if (@alignOf(Callback) < (@alignOf(Priority) << 1))
            @compileError("Architecture not supported");
        return Runnable{
            .link = Link{},
            .state = @ptrToInt(callback) | @enumToInt(priority),
        };
    }

    pub fn getPriority(self: Runnable) Priority {
        return @intToEnum(Priority, @truncate(@TagType(Priority), self.state));
    }

    pub fn getLink(self: *Runnable) *Link {
        return &self.link;
    }

    pub fn fromLink(link: *Link) *Runnable {
        return @fieldParentPtr(Runnable, "link", link);
    }

    pub fn run(
        noalias self: *Runnable,
        noalias context: Context,
    ) ?*Runnable {
        const mask = ~@as(usize, ~@as(@TagType(Priority), 0));
        const callback = @intToPtr(Callback, self.state & mask);
        return (callback)(self, context);
    }
};

pub const Link = extern struct {
    next: ?*Link = null,

    pub const Queue = struct {
        head: ?*Link = null,
        tail: ?*Link = null,
        len: usize = 0,

        pub const Side = enum {
            Front,
            Back,
        };

        pub fn fromLink(link: *Link) Queue {
            var self = Queue{};
            self.push(.Front, link);
            return self;
        }

        pub fn push(
            noalias self: *Queue,
            side: Side,
            noalias link: *Link,
        ) void {
            self.len += 1;
            switch (side) {
                .Front => {
                    link.next = self.head;
                    if (self.tail == null)
                        self.tail = link;
                    self.head = link;
                },
                .Back => {
                    link.next = null;
                    if (self.head == null)
                        self.head = link;
                    if (self.tail) |tail|
                        tail.next = link;
                    self.tail = link;
                }
            }
        }

        pub fn pop(self: *Queue) ?*Link {
            const link = self.head orelse return null;
            self.head = link.next;
            if (self.head == null)
                self.tail = null;
            self.len -= 1;
            return link;
        }

        const Unbounded = extern struct {
            head: *Link align(CACHE_LINE),
            tail: *Link,
            stub: Link,

            fn init(self: *Unbounded) void {
                self.head = &self.stub;
                self.tail = &self.stub;
                self.stub.next = null;
            }

            fn deinit(self: *Unbounded) void {
                assert(self.isEmpty());
            }

            fn isEmpty(self: *const Unbounded) bool {
                const head = @atomicLoad(*Link, &self.head, .Monotonic);
                return head == &self.stub;
            }

            fn push(self: *Unbounded, queue: Queue) void {
                const front = queue.head orelse return;
                const back = queue.tail.?;

                back.next = null;
                const prev = @atomicRmw(*Link, &self.head, .Xchg, back, .AcqRel);
                @atomicStore(?*Link, &prev.next, front, .Release);
            }

            fn pop(self: *Unbounded) ?*Link {
                var tail = self.tail;
                var next = @atomicLoad(?*Link, &tail.next, .Acquire);

                if (tail == &self.stub) {
                    tail = next orelse return null;
                    self.tail = tail;
                    next = @atomicLoad(?*Link, &tail.next, .Acquire);
                }

                if (next) |link| {
                    self.tail = link;
                    return tail;
                }

                const head = @atomicLoad(*Link, &self.head, .Monotonic);
                if (head != tail)
                    return null;

                self.push(Queue.fromLink(&self.stub));
                self.tail = @atomicLoad(?*Link, &tail.next, .Acquire) orelse return null;
                return tail;
            }
        };

        const Index = @Type(std.builtin.TypeInfo{
            .Int = std.builtin.TypeInfo.Int{
                .is_signed = false,
                .bits = @typeInfo(usize).Int.bits / 2,
            },
        });

        fn Bounded(comptime size: Index) type {
            comptime assert(size > 0);

            return extern struct {
                pos: usize align(CACHE_LINE),
                buffer: [size]*Link,

                const Self = @This();

                fn init(self: *Self) void {
                    self.pos = 0;
                    self.buffer = undefined;
                }

                fn deinit(self: *Self) void {
                    assert(self.isEmpty());
                }

                fn isEmpty(self: *const Self) bool {
                    return self.len() == 0;
                }

                fn len(self: *const Self) Index {
                    const pos = @atomicLoad(usize, &self.pos, .Monotonic);
                    const head = decodeHead(pos);
                    const tail = decodeTail(pos);
                    return tail -% head;
                }

                fn push(
                    noalias self: *Self,
                    side: Side,
                    noalias link: *Link,
                    noalias unbounded_queue: *Unbounded,
                ) void {
                    const pos = @atomicLoad(usize, &self.pos, .Monotonic);
                    var head = decodeHead(pos);
                    var tail = decodeTail(pos);

                    while (true) {
                        if (tail -% head < size) {
                            switch (side) {
                                .Front => {
                                    self.buffer[(head -% 1) % size] = link;
                                    head = @cmpxchgWeak(
                                        Index,
                                        self.headPtr(),
                                        head,
                                        head -% 1,
                                        .Release,
                                        .Monotonic,
                                    ) orelse return;
                                    continue;
                                },
                                .Back => {
                                    self.buffer[tail % size] = link;
                                    @atomicStore(Index, self.tailPtr(), tail +% 1, .Release);
                                    return;
                                },
                            }
                        }

                        var migrate = size / 2;
                        var new_tail = tail -% migrate;
                        if (@cmpxchgWeak(
                            usize,
                            &self.pos,
                            encode(head, tail),
                            encode(head, new_tail),
                            .Monotonic,
                            .Monotonic,
                        )) |new_pos| {
                            head = decodeHead(new_pos);
                            continue;
                        }

                        var batch = Queue{};
                        while (migrate != 0) : (migrate -= 1) {
                            const migrated_link = self.buffer[new_tail % size];
                            batch.push(.Back, migrated_link);
                            new_tail +%= 1;
                        }

                        batch.push(side, link);
                        unbounded_queue.push(batch);
                        return;
                    }
                }

                fn pop(self: *Self, side: Side) ?*Link {
                    var pos = @atomicLoad(usize, &self.pos, .Monotonic);

                    while (true) {
                        var head = decodeHead(pos);
                        var tail = decodeTail(pos);
                        if (tail -% head == 0)
                            return null;

                        const link = switch (side) {
                            .Front => blk: {
                                defer head +%= 1;
                                break :blk self.buffer[head % size];
                            },
                            .Back => blk: {
                                tail -%= 1;
                                break :blk self.buffer[tail % size];
                            },
                        };

                        pos = @cmpxchgWeak(
                            usize,
                            &self.pos,
                            pos,
                            encode(head, tail),
                            .Monotonic,
                            .Monotonic,
                        ) orelse return link;
                    }
                }

                fn stealFromBounded(
                    noalias self: *Self,
                    noalias target: *Self,
                ) ?*Link {
                    const pos = @atomicLoad(usize, &self.pos, .Monotonic);
                    const head = decodeHead(pos);
                    const tail = decodeTail(pos);
                    const stealable = size - (tail -% head);
                    if (stealable == 0)
                        return null;

                    var target_pos = @atomicLoad(usize, &target.pos, .Acquire);
                    while (true) {
                        var target_head = decodeHead(target_pos);
                        var target_tail = decodeTail(target_pos);
                        var migrate = switch (target_tail -% target_head) {
                            0 => return null,
                            1 => 1,
                            else => |target_size| std.math.min(stealable, target_size / 2),
                        };

                        var new_tail = tail;
                        var first_link: ?*Link = null;
                        while (migrate != 0) : (migrate -= 1) {
                            const link = target.buffer[target_head % size];
                            target_head +%= 1;
                            if (first_link == null) {
                                first_link = link;
                            } else {
                                self.buffer[new_tail % size] = link;
                                new_tail +%= 1;
                            }
                        }

                        if (@cmpxchgWeak(
                            usize,
                            &target.pos,
                            target_pos,
                            encode(target_head, target_tail),
                            .AcqRel,
                            .Acquire,
                        )) |new_target_pos| {
                            target_pos = new_target_pos;
                            continue;
                        }

                        if (new_tail != tail)
                            @atomicStore(Index, self.tailPtr(), new_tail, .Release);
                        return first_link;
                    }
                }

                fn stealFromUnbounded(
                    noalias self: *Self,
                    noalias unbounded_queue: *Unbounded,
                ) ?*Link {
                    const pos = @atomicLoad(usize, &self.pos, .Monotonic);
                    var head = decodeHead(pos);
                    var tail = decodeTail(pos);

                    var new_tail = tail;
                    var migrate = size - (tail -% head);
                    var first_link: ?*Link = null;

                    while (migrate != 0) : (migrate -= 1) {
                        const link = unbounded_queue.pop() orelse break;
                        if (first_link == null) {
                            first_link = link;
                        } else {
                            self.buffer[new_tail % size] = link;
                            new_tail +%= 1;
                        }
                    }

                    if (new_tail != tail)
                        @atomicStore(Index, self.tailPtr(), new_tail, .Release);
                    return first_link;
                }

                fn encode(head: Index, tail: Index) usize {
                    return @bitCast(usize, [2]Index{ head, tail });
                }

                fn decodeHead(pos: usize) Index {
                    return @bitCast([2]Index, pos)[0];
                }

                fn decodeTail(pos: usize) Index {
                    return @bitCast([2]Index, pos)[1];
                }

                fn headPtr(self: *Self) *Index {
                    return &@ptrCast(*[2]Index, &self.pos)[0];
                }

                fn tailPtr(self: *Self) *Index {
                    return &@ptrCast(*[2]Index, &self.pos)[1];
                }
            };
        }
    };
};

const ABAProtectedAtomicUsize = switch (std.builtin.arch) {
    .i386, .x86_64 => extern struct {
        value: usize align(@alignOf(DoubleWord)),
        aba_tag: usize,

        const DoubleWord = @Type(std.builtin.TypeInfo{
            .Int = std.builtin.TypeInfo.Int{
                .is_signed = false,
                .bits = @typeInfo(usize).Int.bits * 2,
            },
        });

        fn init(value: usize) ABAProtectedAtomicUsize {
            return ABAProtectedAtomicUsize{
                .value = value,
                .aba_tag = 0,
            };
        }

        fn get(self: ABAProtectedAtomicUsize) usize {
            return self.value;
        }

        fn getDirectPtr(self: *ABAProtectedAtomicUsize) *usize {
            return &self.value;
        }

        fn load(
            self: *const ABAProtectedAtomicUsize,
            comptime ordering: std.builtin.AtomicOrder,
        ) ABAProtectedAtomicUsize {
            return ABAProtectedAtomicUsize{
                .value = @atomicLoad(usize, &self.value, ordering),
                .aba_tag = @atomicLoad(usize, &self.aba_tag, .Monotonic),
            };
        }

        fn compareExchange(
            self: *ABAProtectedAtomicUsize,
            compare: ABAProtectedAtomicUsize,
            exchange: usize,
            comptime success_ordering: std.builtin.AtomicOrder,
            comptime failure_ordering: std.builtin.AtomicOrder,
        ) ?ABAProtectedAtomicUsize {
            const new_double_word = @cmpxchgWeak(
                DoubleWord,
                @ptrCast(*DoubleWord, self),
                @bitCast(DoubleWord, compare),
                @bitCast(DoubleWord, ABAProtectedAtomicUsize{
                    .value = exchange,
                    .aba_tag = self.aba_tag +% 1,
                }),
                success_ordering,
                failure_ordering,
            ) orelse return null;
            return @bitCast(ABAProtectedAtomicUsize, new_double_word);
        }
    },
    else => extern struct {
        value: usize,

        fn init(value: usize) ABAProtectedAtomicUsize {
            return ABAProtectedAtomicUsize{ .value = value };
        }

        fn get(self: ABAProtectedAtomicUsize) usize {
            return self.value;
        }

        fn getDirectPtr(self: ABAProtectedAtomicUsize) *usize {
            return &self.value;
        }

        fn load(
            self: *const ABAProtectedAtomicUsize,
            comptime ordering: std.builtin.AtomicOrder,
        ) ABAProtectedAtomicUsize {
            const value = @atomicLoad(usize, &self.value, ordering);
            return init(value);
        }

        fn compareExchange(
            self: *ABAProtectedAtomicUsize,
            compare: ABAProtectedAtomicUsize,
            exchange: usize,
            comptime success_ordering: std.builtin.AtomicOrder,
            comptime failure_ordering: std.builtin.AtomicOrder,
        ) ?ABAProtectedAtomicUsize {
            const new_value = @cmpxchgWeak(
                usize,
                &self.value,
                compare.value,
                exchange,
                success_ordering,
                failure_ordering,
            ) orelse return null;
            return init(new_value);
        }
    },
};

const Guard = extern struct {
    is_acquired: bool align(CACHE_LINE),

    fn init(self: *Guard) void {
        self.is_acquired = false;
    }

    fn deinit(self: *Guard) void {
        assert(@atomicLoad(bool, &self.is_acquired, .Monotonic) == false);
        self.* = undefined;
    }

    fn tryAcquire(self: *Guard) bool {
        if (@atomicLoad(bool, &self.is_acquired, .Monotonic))
            return false;
        return !@atomicRmw(
            bool,
            &self.is_acquired,
            .Xchg,
            true,
            .Acquire,
        );
    }

    fn release(self: *Guard) void {
        @atomicStore(bool, &self.is_acquired, false, .Release);
    }
};

const RandomGenerator = extern struct {
    state: usize,

    fn init(self: *RandomGenerator, seed: usize) void {
        const fib_hash_seed = switch (@typeInfo(usize).Int.bits) {
            32 => 2654435769,
            64 => 11400714819323198485,
            else => @compileError("Architecture not supported"),
        };
        self.state = seed *% fib_hash_seed;
    }

    fn deinit(self: *RandomGenerator) void {
        self.* = undefined;
    }

    fn next(self: *RandomGenerator) usize {
        switch (@typeInfo(usize).Int.bits) {
            32 => {
                self.state ^= self.state << 13;
                self.state ^= self.state >> 17;
                self.state ^= self.state << 5;
            },
            64 => {
                self.state ^= self.state << 13;
                self.state ^= self.state >> 7;
                self.state ^= self.state << 17;
            },
            else => @compileError("Architecture not supported"),
        }
        return self.state;
    }
};

const CACHE_LINE = 
    if (std.builtin.arch == .x86_64) 64 * 2
    else 64;