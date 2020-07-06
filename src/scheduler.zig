const std = @import("std");

pub const Config = struct {
    runnable_buffer: usize = 256,
    cache_line: usize = switch (std.builtin.arch) {
        .x86_64 => 64 * 2,
        else => 64,
    },
};

pub fn Executor(comptime config: Config) type {
    const cache_line = std.math.max(@alignOf(usize), config.cache_line);
    const CACHE_LINE = std.mem.alignForward(cache_line, @alignOf(usize));
    const BUFFER_SIZE = std.math.max(CACHE_LINE / @sizeOf(usize), config.runnable_buffer);

    return struct {
        pub const Node = extern struct {
            pub const Cluster = extern struct {
                head: ?*Node,
                tail: ?*Node,
                len: usize,

                pub fn init() Cluster {
                    return Cluster{
                        .head = null,
                        .tail = null,
                        .len = 0,
                    };
                }

                pub fn push(self: *Cluster, node: *Node) void {
                    if (self.tail) |tail|
                        tail.next = node;
                    self.tail = node;
                    node.next = self.head orelse blk: {
                        self.head = node;
                        break :blk node;
                    };
                    self.len += 1;
                }

                pub fn pop(self: *Cluster) ?*Node {
                    const tail = self.tail orelse return null;
                    const head = tail.next;
                    if (head == tail) {
                        self.head = null;
                        self.tail = null;
                    } else {
                        self.head = head.next;
                        tail.next = head.next;
                    }
                    head.next = head;
                    self.len -= 1;
                    return head;
                }

                pub fn pushAll(self: *Cluster, other: Cluster) void {
                    const other_head = other.head orelse return;
                    if (self.tail) |tail|
                        tail.next = other_head;
                    const head = self.head orelse blk: {
                        self.head = other_head;
                        break :blk other_head;
                    };
                    self.tail = other.tail;
                    other.tail.?.next = head;
                    self.len += other.len;
                }

                pub fn iter(self: Cluster) Iter {
                    return Iter.init(self.head);
                }
            };

            pub const Iter = extern struct {
                start: *Node,
                current: ?*Node,

                fn init(start: ?*Node) Iter {
                    return Iter{
                        .start = start orelse undefined,
                        .current = start,
                    };
                }

                pub fn next(self: *Iter) ?*Node {
                    const node = self.current orelse return null;
                    self.current = node.next;
                    if (self.current == self.start)
                        self.current = null;
                    return node;
                }
            };

            const AtomicUsize = switch (std.builtin.arch) {
                .i386, .x86_64 => extern struct {
                    value: usize align(@alignOf(DoubleWord)),
                    aba_tag: usize = 0,

                    const DoubleWord = @Type(std.builtin.TypeInfo{
                        .Int = std.builtin.TypeInfo.Int{
                            .is_signed = false,
                            .bits = @typeInfo(usize).Int.bits * 2,
                        },
                    });

                    fn load(
                        self: *const AtomicUsize,
                        comptime ordering: std.builtin.AtomicOrder,
                    ) AtomicUsize {
                        return AtomicUsize{
                            .value = @atomicLoad(usize, &self.value, ordering),
                            .aba_tag = @atomicLoad(usize, &self.aba_tag, .SeqCst),
                        };
                    }

                    fn compareExchangeWeak(
                        self: *AtomicUsize,
                        compare: AtomicUsize,
                        exchange: usize,
                        comptime success: std.builtin.AtomicOrder,
                        comptime failure: std.builtin.AtomicOrder,
                    ) ?AtomicUsize {
                        const double_word = @cmpxchgWeak(
                            DoubleWord,
                            @ptrCast(*DoubleWord, self),
                            @bitCast(DoubleWord, compare),
                            @bitCast(DoubleWord, AtomicUsize{
                                .value = exchange,
                                .aba_tag = compare.aba_tag +% 1,
                            }),
                            success,
                            failure,
                        ) orelse return null;
                        return @bitCast(AtomicUsize, double_word);
                    }
                },
                else => extern struct {
                    value: usize,

                    fn load(
                        self: *const AtomicUsize,
                        comptime ordering: std.builtin.AtomicOrder,
                    ) AtomicUsize {
                        const value = @atomicLoad(usize, &self.value, ordering);
                        return AtomicUsize{ .value = value };
                    }

                    fn compareExchangeWeak(
                        self: *AtomicUsize,
                        compare: AtomicUsize,
                        exchange: usize,
                        comptime success: std.builtin.AtomicOrder,
                        comptime failure: std.builtin.AtomicOrder,
                    ) ?AtomicUsize {
                        const value = @cmpxchgWeak(
                            usize,
                            &self.value,
                            compare.value,
                            exchange,
                            success,
                            failure,
                        ) orelse return null;
                        return AtomicUsize{ .value = value };
                    }
                },
            };

            pub const ResumeHandle = extern struct {
                ptr: usize,

                const Tag = enum(u2) {
                    empty,
                    notified,
                    notify,
                    spawn,
                };

                pub const Type = union(Tag) {
                    empty: void,
                    notified: void,
                    notify: *Worker,
                    spawn: *Worker.Slot,
                };

                fn encode(ptr: usize, tag: Tag) ResumeHandle {
                    return ResumeHandle{ .ptr = ptr | @enumToInt(tag) };
                }

                pub fn decode(self: ResumeHandle) Type {
                    const ptr = self.ptr & ~@as(usize, ~@as(@TagType(Tag), 0));
                    const tag = @intToEnum(Tag, @truncate(@TagType(Tag), self.ptr));
                    return switch (tag) {
                        .empty => Type{ .empty = {} },
                        .notified => Type{ .notified = {} },
                        .notify => Type{ .notify = @intToPtr(*Worker, ptr) },
                        .spawn => Type{ .spawn = @intToPtr(*Worker.Slot, ptr) },
                    };
                }
            };

            active_workers: usize align(Worker.Slot.alignment),
            idle_workers: AtomicUsize align(CACHE_LINE),
            runq_head: usize align(CACHE_LINE),
            runq_tail: usize align(CACHE_LINE),
            runq_stub: ?*Runnable,
            next: *Node align(CACHE_LINE),
            active_nodes_ptr: *usize,
            slots_ptr: [*]Worker.Slot,
            slots_len: usize,

            const IdleState = enum(u2) {
                ready,
                waking,
                notified,
                shutdown,
            };

            pub fn iter(self: *Node) Iter {
                return Iter.init(self);
            }

            pub fn tryResumeSomeWorker(self: *Node) ResumeHandle {
                var nodes = self.iter();
                while (nodes.next()) |node| {
                    const handle = node.tryResumeWorker();
                    switch (handle.decode()) {
                        .empty => continue,
                        else => return handle,
                    }
                }
                return ResumeHandle.encode(0, .empty);
            }

            pub fn tryResumeWorker(self: *Node) ResumeHandle {
                var idle_workers = self.idle_workers.load(.SeqCst);
                while (true) {
                    const ptr = idle_workers.value & ~@as(usize, ~@as(@TagType(IdleState), 0));
                    const state = @intToEnum(IdleState, @truncate(@TagType(IdleState), idle_workers.value));

                    var next_ptr = ptr;
                    var next_state = state;
                    var resume_handle: ResumeHandle = undefined;
                    
                    switch (state) {
                        .ready => {
                            if (@intToPtr(?*Worker.Slot, ptr)) |slot| {
                                next_state = .waking;
                                switch (slot.decode()) {
                                    .slot => |next_slot| {
                                        next_ptr = @ptrToInt(next_slot);
                                        resume_handle = ResumeHandle{ .spawn = slot };
                                    },
                                    .worker => |worker| {
                                        next_ptr = worker.next;
                                        resume_handle = ResumeHandle{ .notify = worker };
                                    },
                                    .node => unreachable,
                                    .thread => unreachable,
                                }
                            } else {
                                next_state = .notified;
                                resume_handle = ResumeHandle{ .notified = {} };
                            }
                        },
                        .waking => {
                            next_state = .notified;
                            resume_handle = ResumeHandle{ .notified = {} };
                        },
                        .notified => {
                            return ResumeHandle{ .empty = {} };
                        },
                        .shutdown => unreachable},
                    }

                    idle_workers = self.idle_workers.compareExchangeWeak(
                        idle_workers,
                        next_ptr | @enumToInt(next_state),
                        .SeqCst,
                        .SeqCst,
                    ) orelse return resume_handle;
                }
            }

            fn push(self: *Node, batch: Runnable.Batch) void {
                const head = batch.head.?;
                const tail = batch.tail.?;
                tail.next = null;
                const prev = @atomicRmw(*Runnable, &node.runq_head, .Xchg, tail, .AcqRel);
                @atomicStore(?*Runnable, &prev.next, head, .Release);
            }

            const PopResult = struct {
                runq_tail: *Runnable,
                runnable: ?*Runnable,
            };

            fn pop(self: *Node, runq_tail: *Runnable, runq_stub: *Runnable) PopResult {
                var pop_result: PopResult = undefined;
                pop_result.runq_tail = runq_tail;

                pop_result.runnable = blk: {
                    var tail = pop_result.runq_tail;
                    var next = @atomicLoad(?*Runnable, &tail.next, .Acquire);

                    if (tail == runq_stub) {
                        tail = next orelse break :blk null;
                        pop_result.runq_tail = tail;
                        next = @atomicLoad(?*Runnable, &tail.next, .Acquire); 
                    }

                    if (next) |next_tail| {
                        pop_result.runq_tail = next_tail;
                        break :blk tail;
                    }

                    const head = @atomicLoad(*Runnable, &self.runq_head, .Monotonic);
                    if (head != tail)
                        break :blk null;

                    var batch = Runnable.Batch.init();
                    batch.push(runq_stub);
                    self.push(batch);

                    next = @atomicLoad(?*Runnable, &tail.next, .Acquire);
                    pop_result.runq_tail = next orelse break :blk null;
                    break :blk tail;
                };
                
                return pop_result;
            }
        };

        pub const Worker = extern struct {
            pub const Slot = extern struct {
                ptr: usize align(alignment),

                const alignment = 1 << @typeInfo(@TagType(Node.IdleState)).Int.bits;

                const Tag = enum(u2) {
                    slot,
                    node,
                    worker,
                    thread,
                };

                const Type = union(Tag) {
                    slot: ?*Slot,
                    node: *Node,
                    worker: *Worker,
                    thread: usize,
                };

                fn encode(ptr: usize, tag: Tag) Slot {
                    return Slot{ .ptr = ptr | @enumToInt(tag) };
                }

                fn decode(self: Slot) Type {
                    const ptr = self.ptr & ~@as(usize, ~@as(@TagType(Tag), 0));
                    const tag = @intToEnum(Tag, @truncate(@TagType(Tag), self.ptr));
                    return switch (tag) {
                        .slot => Type{ .slot = @intToPtr(?*Slot, ptr) },
                        .node => Type{ .node = @intToPtr(*Node, ptr) },
                        .worker => Type{ .worker = @intToPtr(*Worker, ptr) },
                        .thread => Type{ .thread = ptr },
                    };
                }
            };

            const State = enum(u8) {
                stopped,
                waking,
                suspended,
                running,
            };

            const Action = union(enum) {
                @"suspend": void,
                @"resume": *Worker,
                @"async": *Worker.Slot,
                @"await": void,
            };

            runq_head: usize align(Slot.alignment),
            runq_tail: usize align(CACHE_LINE),
            runq_buffer: [BUFFER_SIZE]*Runnable align(CACHE_LINE),
            node: *Node,
            slot: *Slot,
            thread: usize,
            next: usize,
            state: u32,

            fn encodeState(state: State, tick: u8, rng: u16) u32 {
                return (
                    (@as(u32, @enumToInt(state)) << 24) |
                    (@as(u32, tick) << 16) |
                    @as(u32, rng)
                );
            }

            pub fn init(
                noalias self: *Worker,
                noalias slot: *Slot,
                thread: usize,
            ) void {
                const slot_value = Slot{ .ptr = @atomicLoad(usize, &slot.ptr, .Acquire) };
                const node = slot_value.decode().node;

                self.* = Worker{
                    .runq_head = 0,
                    .runq_tail = 0,
                    .runq_buffer = undefined,
                    .node = node,
                    .slot = slot,
                    .thread = thread,
                    .next = undefined,
                    .state = encodeState(.waking, 0, @truncate(u16, @ptrToInt(slot) ^ @ptrToInt(self))),
                };

                const new_value = Slot.encode(@ptrToInt(self), .worker).ptr;
                @atomicStore(usize, &slot.ptr, new_value, .Release);
            }

            pub fn run(self: *Worker) Action {
                const raw_state = self.state;
                var state = @intToEnum(State, @truncate(u8, raw_state >> 24));
                var tick = @truncate(u8, raw_state >> 16);
                var rng = @truncate(u16, raw_state);

                if (state == .stopped)
                    return Action{ .@"await" = {} };
                if (state == .suspended)
                    return Action{ .@"suspend" = {} };

                const node = self.node;
                while (true) {
                    var should_wake = false;
                    const polled_runnable = @intToPtr(?*Runnable, self.next) orelse blk: {
                        if (state != .waking) {
                            if (tick % 61 == 0) {
                                if (self.pollNode(node)) |runnable| {
                                    should_wake = true;
                                    break :blk runnable;
                                }
                            }

                            if (self.pollLocal()) |runnable| {
                                break :blk runnable;
                            }
                        }

                        var steal_attempts: u3 = 4;
                        while (steal_attempts != 0) : (steal_attempts -= 1) {
                            var nodes = node.iter();
                            while (nodes.next()) |target_node| {

                                if (self.pollNode(target_node)) |runnable| {
                                    should_wake = true;
                                    break :blk runnable;
                                }

                                const slots = target_node.slots_ptr;
                                const num_slots = target_node.slots_len;
                                var index = rng_index: {
                                    rng ^= rng << 7;
                                    rng ^= rng >> 9;
                                    rng ^= rng << 8;
                                    break :rng_index (rng % num_slots);
                                };

                                var i = num_slots;
                                while (i != 0) : (i -= 1) {
                                    defer {
                                        index += 1;
                                        if (index == num_slots)
                                            index = 0;
                                    }

                                    const slot_value = @atomicLoad(usize, &slots[index].ptr, .Acquire);
                                    switch ((Slot{ .ptr = slot_value }).decode()) {
                                        .worker => |worker| {
                                            if (worker == self)
                                                continue;
                                            if (self.pollWorker(worker)) |runnable| {
                                                break :blk runnable;
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            }
                        }

                        break :blk null;
                    };

                    if (polled_runnable) |runnable| {
                        
                        const resume_ptr = switch (
                            if (state == .waking)
                                node.tryResumeWorkerAfterWaking()
                            else if (should_wake)
                                node.tryResumeSomeWorker()
                            else
                                ResumeHandle{ .empty = {} }
                        ) {
                            .empty, .notified => 0,
                            .notify => |worker| @ptrToInt(worker) | 1,
                            .spawn => |slot| @ptrToInt(slot),
                        };
                        
                        self.next = @ptrToInt(runnable);
                        self.state = encodeState(.running, tick, rng);
                        if (resume_ptr & 1 != 0)
                            return Action{ .@"resume" = @intToPtr(*Worker, resume_ptr & ~@as(usize, 1)) };
                        if (resume_ptr != 0)
                            return Action{ .@"async" = @intToEnum(*Worker.Slot, resume_ptr) };

                        var batch = (runnable.callback)(self, runnable);
                        self.next = @intToPtr(batch.pop());
                        if (self.next == 0 or batch.len == 0)
                            continue;
                        
                        node.push(batch);
                        switch (node.tryResumeSomeWorker()) {
                            .empty, .notified => continue,
                            .notify => |worker| return Action{ .@"resume" = worker },
                            .spawn => |slot| return Action{ .@"async" = slot },
                        }
                    }

                    // TODO: suspend
                }
            }
        };

        pub const Runnable = extern struct {
            pub const Callback = fn(
                *Worker,
                *Runnable,
            ) callconv(.C) Batch;

            pub const Batch = extern struct {
                head: ?*Runnable,
                tail: ?*Runnable,
                len: usize,

                pub fn init() Batch {
                    return Batch{
                        .head = null,
                        .tail = null,
                        .len = 0,
                    };
                }

                pub fn pushAll(self: *Batch, other: Batch) void {
                    if (other.len == 0)
                        return;
                    if (self.tail) |tail|
                        tail.next = other.head;
                    if (self.head == null)
                        self.head = other.head;
                    self.tail = other.tail;
                    self.len += other.len;
                }

                pub fn push(self: *Batch, runnable: *Runnable) void {
                    if (self.head == null)
                        self.head = runnable;
                    if (self.tail) |tail|
                        tail.next = runnable;
                    self.tail = runnable;
                    runnable.next = null;
                    self.len += 1;
                }

                pub fn pop(self: *Batch) ?*Runnable {
                    const runnable = self.head orelse return null;
                    self.head = runnable.next;
                    if (self.head == null)
                        self.tail = null;
                    self.len -= 1;
                    return runnable;
                }
            };

            next: ?*Runnable,
            callback: Callback,


        };
    };
}