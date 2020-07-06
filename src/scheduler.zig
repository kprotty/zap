const std = @import("std");

const HalfWord = @Type(std.builtin.TypeInfo{
    .Int = std.builtin.TypeInfo.Int{
        .is_signed = false,
        .bits = @typeInfo(usize).Int.bits / 2,
    },
});

const DoubleWord = @Type(std.builtin.TypeInfo{
    .Int = std.builtin.TypeInfo.Int{
        .is_signed = false,
        .bits = @typeInfo(usize).Int.bits * 2,
    },
});

pub const Config = struct {
    worker_buffer: HalfWord = 256,
    cache_line: usize = switch (std.builtin.arch) {
        .x86_64 => 64 * 2,
        else => 64,
    },
};

pub fn Executor(comptime config: Config) type {
    const cache_line = std.math.max(@alignOf(usize), config.cache_line);
    const CACHE_LINE = std.mem.alignForward(cache_line, @alignOf(usize));
    const BUFFER_SIZE = std.math.max(CACHE_LINE / @sizeOf(usize), config.worker_buffer);

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
            runq_head: *Runnable align(CACHE_LINE),
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
                return self.tryResumeWorkerWhen(false);
            }

            fn tryResumeWorkerAfterWaking(self: *Node) ResumeHandle {
                return self.tryResumeWorkerWhen(true);
            }

            fn tryResumeWorkerWhen(self: *Node, is_waking: bool) ResumeHandle {
                var idle_workers = self.idle_workers.load(.SeqCst);
                while (true) {
                    const ptr = idle_workers.value & ~@as(usize, ~@as(@TagType(IdleState), 0));
                    const state = @intToEnum(IdleState, @truncate(@TagType(IdleState), idle_workers.value));
                    std.debug.assert(state != .shutdown);

                    var next_ptr = ptr;
                    var next_state = state;
                    var resume_handle = ResumeHandle{ .empty = {} };

                    if (is_waking) {
                        if (state == .ready)
                            return resume_handle;
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
                        } else if (state == .waking) {
                            next_state = .ready;
                        }
                    } else {
                        if (state == .notified)
                            return resume_handle;
                        next_state = .notified;
                        resume_handle = ResumeHandle{ .notified = {} };
                        if (state == .ready) {
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
                            }
                        }
                    }

                    if (self.idle_workers.compareExchangeWeak(
                        idle_workers,
                        next_ptr | @enumToInt(next_state),
                        .SeqCst,
                        .SeqCst,
                    )) |new_idle_workers| {
                        idle_workers = new_idle_workers;
                        continue;
                    }

                    if (@atomicRmw(usize, &self.active_workers, .Add, 1, .SeqCst) == 0)
                        _ = @atomicRmw(usize, self.active_nodes_ptr, .Add, 1, .SeqCst);
                    
                    switch (resume_handle.decode()) {
                        .notify => |worker| {
                            var new_state = worker.state.decode();
                            std.debug.assert(new_state.status == .suspended);
                            new_state.status = .waking;
                            worker.state = Worker.State.encode(new_state);
                        },
                        .spawn => |slot| {
                            const new_slot_ptr = Slot.encode(@ptrToInt(self), .node).ptr;
                            @atomicStore(usize, &slot.ptr, new_slot_ptr, .Release);
                        },
                        else => {},
                    }

                    return resume_handle;
                }
            }

            fn trySuspendWorker(noalias self: *Node, noalias worker: *Worker, is_waking: bool) void {
                const slot = worker.slot;
                std.debug.assert(worker.state.decode().status == .suspended);

                var idle_workers = self.idle_workers.load(.SeqCst);
                while (true) {
                    const ptr = idle_workers.value & ~@as(usize, ~@as(@TagType(IdleState), 0));
                    const state = @intToEnum(IdleState, @truncate(@TagType(IdleState), idle_workers.value));
                    std.debug.assert(state != .shutdown);

                    var next_ptr = ptr;
                    var next_state = state;
                    
                    if (ptr == 0 and state == .notified) {
                        next_state = .ready;
                    } else {
                        worker.next = next_ptr;
                        next_ptr = @ptrToInt(worker);
                    }

                    if (self.idle_workers.compareExchangeWeak(
                        idle_workers,
                        next_ptr | @enumToInt(next_state),
                        .SeqCst,
                        .SeqCst,
                    )) |new_idle_workers| {
                        idle_workers = new_idle_workers;
                        continue;
                    }

                    if (state == .notified and next_state == .ready) {
                        var new_state = worker.state.decode()
                        new_state.status = if (is_waking) .waking else .running;
                        worker.state = Worker.State.encode(new_state);

                    } else if (@atomicRmw(usize, &self.active_workers, .Sub, 1, .SeqCst) == 1) {
                        if (@atomicRmw(usize, self.active_nodes_ptr, .Sub, 1, .SeqCst) == 1) {
                            self.shutdown(worker);
                        }
                    }

                    return;
                }
            }

            fn shutdown(noalias self: *Node, noalias initiator: *Worker) void {
                var idle_workers = @atomicRmw(
                    usize,
                    &self.idle_workers.value,
                    .Xchg,
                    @enumToInt(IdleState.shutdown),
                    .AcqRel,
                );

                var 
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

            const State = extern struct {
                value: u32,

                const Status = enum(u8) {
                    stopped,
                    waking,
                    suspended,
                    running,
                };

                const Value = extern struct {
                    status: Status,
                    tick: u8,
                    rng: u16,
                };

                fn encode(value: Value) State {
                    return State{
                        .value = 
                            (@as(u32, @enumToInt(value.status)) << 24) |
                            (@as(u32, value.tick) << 16) |
                            @as(u32, value.rng)
                    );
                }

                fn decode(state: State) Value {
                    return Value{
                        .status = @intToEnum(Status, @truncate(u8, self.value >> 24)),
                        .tick = @truncate(u8, self.value >> 16),
                        .rng = @truncate(u16, self.value),
                    };
                }
            };

            const Syscall = union(enum) {
                @"suspend": void,
                @"resume": *Worker,
                @"async": *Worker.Slot,
                @"await": usize,
            };

            runq_pos: usize align(Slot.alignment),
            runq_buffer: [BUFFER_SIZE]*Runnable align(CACHE_LINE),
            node: *Node,
            slot: *Slot,
            thread: usize,
            next: usize,
            state: u32,

            pub fn init(
                noalias self: *Worker,
                noalias slot: *Slot,
                thread: usize,
            ) void {
                const slot_value = Slot{ .ptr = @atomicLoad(usize, &slot.ptr, .Acquire) };
                const node = slot_value.decode().node;

                self.* = Worker{
                    .runq_pos = 0,
                    .runq_buffer = undefined,
                    .node = node,
                    .slot = slot,
                    .thread = thread,
                    .next = undefined,
                    .state = State.encode(.{
                        .status = .waking,
                        .tick = 0,
                        .rng = @truncate(u16, @ptrToInt(slot) ^ @ptrToInt(self)),
                    }),
                };

                const new_value = Slot.encode(@ptrToInt(self), .worker).ptr;
                @atomicStore(usize, &slot.ptr, new_value, .Release);
            }

            pub fn run(self: *Worker) Syscall {
                while (true) {
                    var state = self.state.decode();
                    if (state.status == .stopped)
                        return Syscall{ .@"await" = self.thread };
                    if (state.status == .suspended)
                        return Syscall{ .@"suspend" = {} };

                    const node = self.node;
                    poll: while (true) {
                        var wake_worker = false;
                        const polled_runnable = @intToPtr(?*Runnable, self.next) orelse blk: {
                            break :blk self.poll(node, &state, &wake_worker);
                        };
                        
                        self.next = @ptrToInt(polled_runnable);
                        var runnable = polled_runnable orelse break :poll;
                        
                        state.status = .running;
                        self.state = State.encode(state);
                        const resume_handle = 
                            if (state.status == .waking)
                                node.tryResumeWorkerAfterWaking()
                            else if (wake_worker)
                                node.tryResumeSomeWorker()
                            else
                                ResumeHandle{ .empty = {} };

                        switch (resume_handle.decode()) {
                            .empty, .notified => {},
                            .notify => |worker| return Syscall{ .@"resume" = worker },
                            .spawn => |slot| return Syscall{ .@"async" = slot },
                        }

                        state.tick +%= 1;
                        self.state = State.encode(state);
                        var batch = (runnable.callback)(self, runnable);

                        self.next = @ptrToInt(batch.pop());
                        runnable = batch.head orelse continue :poll;

                        if (batch.len == 1)
                            const pos = @atomicLoad(usize, &self.runq_pos, .Monotonic);
                            const head = @bitCast([2]HalfWord, pos)[0];
                            const tail = @bitCast([2]HalfWord, pos)[1];
                            if (tail -% head < self.runq_buffer.len) {
                                const tail_ptr = &@ptrCast(*[2]HalfWord, &self.runq_pos)[1];
                                self.runq_buffer[tail % self.runq_buffer.len] = runnable;
                                @atomicStore(HalfWord, tail_ptr, tail +% 1, .Release);
                                _ = batch.pop();
                            }
                        }

                        if (batch.len != 0)
                            node.push(batch);

                        switch (node.tryResumeSomeWorker()) {
                            .empty, .notified => {},
                            .notify => |worker| return Syscall{ .@"resume" = worker },
                            .spawn => |slot| return Syscall{ .@"async" = slot },
                        }
                    }

                    state.status = .suspended;
                    self.state = State.encode(state);
                    node.trySuspendWorker(self);
                }
            }

            inline fn poll(
                self: *Worker,
                node: *Node,
                state: *State.Value,
                wake_worker: *bool,
            ) ?*Runnable {
                if (state.tick % 61 == 0) {
                    if (self.pollNode(node)) |runnable| {
                        wake_worker.* = true;
                        return runnable;
                    }
                }

                if (self.pollLocal()) |runnable| {
                    return runnable;
                }

                var steal_attempts: u3 = 4;
                while (steal_attempts != 0) : (steal_attempts -= 1) {
                    var nodes = node.iter();
                    while (nodes.next()) |target_node| {
                        
                        if (self.pollNode(target_node)) |runnable| {
                            wake_worker.* = true;
                            return runnable;
                        }

                        const num_slots = target_node.slots_len;
                        var index = blk: {
                            var rng = state.rng;
                            rng ^= rng << 7;
                            rng ^= rng >> 9;
                            rng ^= rng << 8;
                            break :blk (rng % num_slots);
                        };

                        const slots = target_node.slots_ptr;
                        var i = num_slots;
                        while (i != 0) : ({
                            i -= 1;
                            index += 1;
                            if (index == num_slots)
                                index = 0;
                        }) {
                            const target_slot_ptr = @atomicLoad(usize, &slots[index].ptr, .Acquire);
                            switch ((Slot{ .ptr = target_slot_ptr }).decode()) {
                                .slot, .node => {},
                                .thread => unreachable,
                                .worker => |target_worker| {
                                    if (target_worker != self) {
                                        if (self.pollWorker(target_worker)) |runnable| {
                                            return runnable;
                                        }
                                    }
                                },
                            }
                        }
                    }
                }

                return null;
            }

            fn pollLocal(self: *Worker) ?*Runnable {
                const pos = @atomicLoad(usize, &self.runq_pos, .Monotonic);
                const tail = @bitCast([2]HalfWord, pos)[1];
                var head = @bitCast([2]HalfWord, pos)[0];

                while (true) {
                    if (tail == head)
                        return null;

                    head = @cmpxchgWeak(
                        HalfWord,
                        &@ptrCast(*[2]HalfWord, &self.runq_pos)[0],
                        head,
                        head +%= 1,
                        .Monotonic,
                        .Monotonic,
                    ) orelse return self.runq_buffer[head % self.runq_buffer.len];
                }
            }

            fn pollNode(noalias self: *Worker, noalias node: *Node) ?*Runnable {
                var runq_tail = @atomicLoad(usize, &node.runq_tail, .Monotonic);
                while (true) {
                    if (runq_tail & 1 != 0)
                        return null;
                    runq_tail = @cmpxchgWeak(
                        usize,
                        &node.runq_tail,
                        runq_tail,
                        runq_tail | 1,
                        .Acquire,
                        .Monotonic,
                    ) orelse break;
                }

                const runq_stub = @fieldParentPtr(Runnable, "next", &node.runq_stub);
                var pop_result: Node.PopResult = undefined;
                pop_result.runq_tail = @intToPtr(*Runnable, runq_tail & ~@as(usize, 1));

                pop_result = node.pop(pop_result.runq_tail, runq_stub);
                const first_runnable = pop_result.runnable;

                const pos = @atomicLoad(usize, &self.runq_pos, .Monotonic);
                const head = @bitCast([2]HalfWord, pos)[0];
                const tail = @bitCast([2]HalfWord, pos)[1];

                var new_tail = tail;
                var steal = self.runq_buffer.len - (tail -% head);
                while (steal != 0) : ({
                    steal -= 1;
                    new_tail +%= 1;
                }) {
                    pop_result = node.pop(pop_result.runq_tail, runq_stub);
                    const runnable = pop_result.runnable orelse break;
                    self.runq_buffer[new_tail % self.runq_buffer.len] = runnable;
                }

                @atomicStore(usize, &node.runq_tail, @ptrToInt(pop_result.runq_tail), .Release);

                if (new_tail != tail) {
                    const tail_ptr = &@ptrCast(*[2]HalfWord, &self.runq_pos)[1];
                    @atomicStore(HalfWord, tail_ptr, new_tail, .Release);
                }
                return first_runnable;
            }

            fn pollWorker(noalias self: *Worker, noalias target: *Worker) ?*Runnable {
                const pos = @atomicLoad(usize, &self.runq_pos, .Monotonic);
                const head = @bitCast([2]HalfWord, pos)[0];
                const tail = @bitCast([2]HalfWord, pos)[1];
                std.debug.assert(tail == head);

                var spin: u5 = 1;
                while (true) {
                    const target_pos = @atomicLoad(usize, &target.runq_pos, .Acquire);
                    const target_head = @bitCast([2]HalfWord, target_pos)[0];
                    const target_tail = @bitCast([2]HalfWord, target_pos)[1];

                    var steal = target_tail -% target_head;
                    steal = steal - (steal / 2);
                    if (steal == 0)
                        return null;
                    
                    var new_target_head = target_head;
                    const first_runnable = target.runq_buffer[new_target_head % target.runq_buffer.len];
                    new_target_head +%= 1;
                    steal -= 1;

                    var new_tail = tail;
                    while (steal != 0) : ({
                        steal -= 1;
                        new_tail +%= 1;
                        new_target_head +%= 1;
                    }) {
                        const runnable = target.runq_buffer[new_target_head % target.runq_buffer.len];
                        self.runq_buffer[new_tail % self.runq_buffer.len] = runnable;
                    }

                    if (@cmpxchgWeak(
                        HalfWord,
                        &@ptrCast(*[2]HalfWord, &target.runq_pos)[0],
                        target_head,
                        new_target_head,
                        .AcqRel,
                        .Release,
                    )) |_| {
                        std.SpinLock.loopHint(@as(usize, spin));
                        spin +%= 1;
                        continue;
                    }

                    if (new_tail != tail) {
                        const tail_ptr = &@ptrCast(*[2]HalfWord, &self.runq_pos)[1];
                        @atomicStore(HalfWord, tail_ptr, new_tail, .Release);
                    }
                    return first_runnable;
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