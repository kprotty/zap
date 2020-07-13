const std = @import("std");

pub const Platform = struct {
    thread_buffer: usize = 256,
    cache_line: u29 = switch (std.builtin.arch) {
        .x86_64 => 64 * 2,
        else => 64,
    },

    pub const AtomicUsize = struct {
        value: usize,

        pub fn init(value: usize) AtomicUsize {
            return AtomicUsize{ .value = value };
        }

        pub fn get(self: AtomicUsize) usize {
            return self.value;
        }

        pub fn set(self: *AtomicUsize, value: usize) void {
            self.value = value;
        }

        pub fn load(
            self: *const AtomicUsize,
            comptime ordering: std.builtin.AtomicOrder,
        ) AtomicUsize {
            const value = @atomicLoad(usize, &self.value, ordering);
            return AtomicUsize{ .value = value };
        }

        pub fn store(
            self: *AtomicUsize,
            value: AtomicUsize,
            comptime ordering: std.builtin.AtomicOrder,
        ) void {
            @atomicStore(usize, &self.value, value, ordering);
        }

        pub fn swap(
            self: *AtomicUsize,
            value: AtomicUsize,
            comptime ordering: std.builtin.AtomicOrder,
        ) AtomicUsize {
            const new_value = @atomicRmw(usize, &self.value, .Xchg, value.get(), ordering);
            return AtomicUsize{ .value = new_value };
        }

        pub fn fetchAdd(
            self: *AtomicUsize,
            value: AtomicUsize,
            comptime ordering: std.builtin.AtomicOrder,
        ) AtomicUsize {
            const new_value = @atomicRmw(usize, &self.value, .Add, value.get(), ordering);
            return AtomicUsize{ .value = new_value };
        }

        pub fn compareExchange(
            self: *AtomicUsize,
            compare: AtomicUsize,
            exchange: AtomicUsize,
            comptime success: std.builtin.AtomicOrder,
            comptime failure: std.builtin.AtomicOrder,
        ) ?AtomicUsize {
            const new_value = @cmpxchgWeak(
                usize,
                &self.value,
                compare.get(),
                exchange.get(),
                success,
                failure,
            ) orelse return null;
            return AtomicUsize{ .value = new_value };
        }

        pub fn testAndSet(
            self: *AtomicUsize,
            comptime ordering: std.builtin.AtomicOrder,
        ) bool {
            return switch (std.builtin.arch) {
                .i386 => asm volatile(
                    \\ lock btsl $0, %[ptr]
                    \\ setnc %[was_set]
                    : [was_set] "=r" (-> bool),
                    : [ptr] "*m" (ptr),
                    : "cc", "memory"
                ),
                .x86_64 => asm volatile(
                    \\ lock btsq $0, %[ptr]
                    \\ setnc %[was_set]
                    : [was_set] "=r" (-> bool),
                    : [ptr] "*m" (ptr),
                    : "cc", "memory"
                ),
                else => self.swap(1, ordering).get() == 0,
            };
        }

        pub fn clear(
            self: *AtomicUsize,
            comptime ordering: std.builtin.AtomicOrder,
        ) void {
            return self.store(0, ordering);
        }
    };
};

pub fn Executor(comptime platform: Platform) type {
    const AtomicUsize = platform.AtomicUsize;
    const BUFFER_SIZE = std.math.max(1, platform.thread_buffer);
    const CACHE_LINE = std.mem.alignForward(platform.cache_line, @alignOf(usize));

    return struct {
        pub const Scheduler = extern struct {
            nodes_active: usize,
            node_cluster: Node.Cluster,

            pub const Error = error {
                EmptyCluster,
                EmptyWorkers,
                InvalidStartingNode,
            };

            pub fn init(
                noalias self: *Scheduler,
                cluster: Node.Cluster,
                starting_node_index: usize,
                noalias starting_runnable: *Runnable,
            ) !*Worker {
                if (cluster.len() == 0)
                    return error.EmptyCluster;

                var start_node: ?*Node = null;
                var node_index: usize = 0;
                var node_iter = cluster.iter();
                while (node_iter.next()) |node| {
                    if (node_index == starting_node_index)
                        start_node = node;
                    node.initUsing(self);
                    node_index += 1;
                }

                const starting_node = start_node orelse return error.InvalidStartingNode;
            }

            pub fn deinit(
                self: *Scheduler,
            )
        };

        pub const Node = extern struct {
            pub const Cluster = extern struct {
                head: ?*Node,
                tail: *Node,
                size: usize,

                pub fn init() Cluster {
                    return initFrom(null);
                }

                pub fn from(node: *Node) Cluster {
                    return initFrom(node);
                }

                fn initFrom(node: ?*Node) Cluster {
                    return Cluster{
                        .head = node,
                        .tail = node orelse undefined,
                        .size = if (node == null) 0 else 1,
                    };
                }

                pub fn len(self: Cluster) usize {
                    return self.size;
                }

                pub fn pushFront(noalias self: *Cluster, noalias node: *Node) void {
                    return self.pushFrontMany(Cluster.from(node));
                }

                pub fn pushBack(noalias self: *Cluster, noalias node: *Node) void {
                    return self.pushBackMany(Cluster.from(node));
                }

                pub fn pushFrontMany(noalias self: *Cluster, cluster: Cluster) void {
                    return self.pushCluster(.front, cluster);
                }

                pub fn pushBackMany(noalias self: *Cluster, cluster: Cluster) void {
                    return self.pushCluster(.back, cluster);
                }
                
                const Side = enum {
                    front,
                    back,
                };

                fn pushCluster(self: *Cluster, side: Side, cluster: Cluster) void {
                    const cluster_head = cluster.head orelse return;
                    if (self.head) |head| {
                        self.size += cluster.size;
                        const cluster_tail = cluster.tail;
                        cluster_tail.next = head;
                        self.tail.next = cluster_head;
                        switch (side) {
                            .front => self.head = cluster_head,
                            .back => self.tail = cluster_tail,
                        }
                    } else {
                        self.* = cluster;
                    }
                }

                pub fn popFront(noalias self: *Cluster) ?*Node {
                    const node = self.head orelse return null;
                    self.size -= 1;
                    self.head = node.next;
                    if (self.head == self.tail)
                        self.head = null;
                    node.next = node;
                    return node;
                }

                pub fn iter(self: Cluster) Iter {
                    Iter.from(self.head);
                }
            };

            pub const Iter = extern struct {
                start: ?*Node,
                node: ?*Node,

                fn from(node: ?*Node) Iter {
                    return Iter{
                        .start = node,
                        .node = node,
                    };
                }

                pub fn next(noalias self: *Iter) ?*Node {
                    const node = self.node orelse return null;
                    self.node = node.next;
                    if (self.node == self.start)
                        self.node = null;
                    return node;
                }
            };

            const IdleState = enum(u2) {
                ready = 3,
                waking = 2,
                notified = 1,
                shutdown = 0,
            };

            const MAX_SLOTS = (@as(usize, 1) << (@typeInfo(usize).Int.bits - 10)) - 1;

            workers_active: AtomicUsize,
            idle_queue: AtomicUsize align(CACHE_LINE),
            runq_polling: AtomicUsize align(CACHE_LINE),
            runq_head: *Runnable align(CACHE_LINE),
            runq_tail: *Runnable align(CACHE_LINE),
            runq_next: ?*Runnable,
            next: *Node align (CACHE_LINE),
            scheduler: *Scheduler,
            slots_ptr: [*]Thread.Slot,
            slots_len: usize,

            pub fn init(slots: []Thread.Slot) Node {
                var self: Node = undefined;
                self.slots_ptr = slots.ptr;
                self.slots_len = std.math.min(MAX_SLOTS, slots.len);
                return self;
            }

            fn initUsing(
                noalias self: *Node,
                noalias scheduler: *Scheduler,
            ) void {
                var idle_queue: usize = 0;
                for (self.slots_ptr[0..self.slots_len]) |*slot| {

                }

                self.workers_active = AtomicUsize.init(0);
                self.idle_queue = AtomicUsize.init(idle_queue);

                const runq_stub = @fieldParentPtr(Runnable, "next", &self.runq_next);
                self.runq_polling = AtomicUsize.init(@boolToInt(false));
                self.runq_head = runq_stub;
                self.runq_tail = runq_stub;
                
                self.next = self;
                self.scheduler = scheduler;
            }

            fn deinit(self: *Node) void {
                defer self.* = undefined;

                const workers_active = self.workers_active.load(.SeqCst).get();
                if (workers_active != 0)
                    std.debug.panic("Node.deinit() when workers_active = {}", .{workers_active});

                const idle_queue = self.idle_queue.load(.SeqCst).get();
                const idle_state = @enumToInt(IdleState, @truncate(@TagType(IdleState), idle_queue));
                if (idle_state != .shutdown)
                    std.dbeug.panic("Node.deinit() when idle_state = {}", .{idle_state});

                const runq_polling = self.runq_polling.load(.SeqCst).get() == 0;
                if (runq_polling)
                    std.debug.panic("Node.deinit() when run queue still polling", .{});

                const runq_head = self.runq_head.load(.SeqCst).get();
                const runq_stub = @fieldParentPtr(Runnable, "next", &self.runq_next);
                if (runq_head != runq_stub)
                    std.debug.panic("Node.deinit() when run queue not empty", .{});
            }
        };

        pub const Thread = extern struct {
            pub const Slot = extern struct {
                ptr: AtomicUsize align(4),
            };

            runq_head: AtomicUsize,
            runq_tail: AtomicUsize align(CACHE_LINE),
            runq_next: ?*Runnable,
            runq_buffer: [THREAD_BUFFER]*Runnable align(CACHE_LINE),
            next: usize,
            node: *Node,

        };

        pub const Runnable = extern struct {
            pub const Batch = extern struct {
                head: ?*Runnable,
                tail: *Runnable,
                size: usize,

                pub fn init() Batch {
                    return initFrom(null);
                }

                pub fn from(runnable: *Runnable) Batch {
                    return initFrom(runnable);
                }

                fn initFrom(runnable: ?*Runnable) Batch {
                    if (runnable) |runnable_ref|
                        runnable_ref.next.set(0);
                    return Batch{
                        .head = runnable,
                        .tail = runnable orelse undefined,
                        .size = if (runnable == null) 0 else 1,
                    };
                }

                pub fn len(self: Batch) usize {
                    return self.size;
                }

                pub fn pushFront(noalias self: *Batch, noalias runnable: *Runnable) void {
                    return self.pushFrontMany(Batch.from(runnable));
                }

                pub fn pushBack(noalias self: *Batch, noalias runnable: *Runnable) void {
                    return self.pushBackMany(Batch.from(runnable));
                }

                pub fn pushFrontMany(noalias self: *Batch, batch: Batch) void {
                    return self.pushBatch(.front, batch);
                }

                pub fn pushBackMany(noalias self: *Batch, batch: Batch) void {
                    return self.pushBatch(.back, batch);
                }
                
                const Side = enum {
                    front,
                    back,
                };

                fn pushBatch(self: *Batch, side: Side, batch: Batch) void {
                    const batch_head = batch.head orelse return;
                    if (self.head) |head| {
                        self.size += batch.size;
                        const batch_tail = batch.tail;
                        switch (side) {
                            .front => {
                                batch_tail.next.set(@ptrToInt(head));
                                self.head = batch_head;
                            },
                            .back => {
                                self.tail.next.set(@ptrToInt(batch_head));
                                self.tail = batch_tail;
                            },
                        }
                    } else {
                        self.* = batch;
                    }
                }

                pub fn popFront(noalias self: *Batch) ?*Runnable {
                    const runnable = self.head orelse return null;
                    self.size -= 1;
                    self.head = @intToPtr(?*Runnable, runnable.next.get());
                    return runnable;
                }

                pub fn iter(self: Batch) Iter {
                    Iter.from(self.head);
                }
            };

            pub const Iter = extern struct {
                runnable: ?*Runnable,

                fn from(runnable: ?*Runnable) Iter {
                    return Iter{ .runnable = runnable };
                }

                pub fn next(noalias self: *Iter) ?*Runnable {
                    const runnable = self.runnable orelse return null;
                    self.runnable = @intToPtr(?*Runnable, runnable.next.get());
                    return runnable;
                }
            };

            pub const Context = extern struct {
                thread: *Thread,

            };

            pub const Callback = fn(
                noalias *Runnable,
                noalias *Context,
            ) callconv(.C) void;

            pub const Hint = enum(u1) {
                Fifo = 0,
                Lifo = 1,
            };

            next: AtomicUsize,
            data: usize,

            pub fn init(hint: Hint, callback: Callback) Runnable {
                return Runnable{
                    .next = AtomicUsize.init(undefined),
                    .data = @ptrToInt(callback) | @enumToInt(hint),
                };
            }

            fn getHint(self: Runnable) Hint {
                return @intToEnum(Hint, @truncate(@TagType(Hint), self.data));
            }

            pub fn run(
                noalias self: *Runnable,
                noalias context: *Context,
            ) void {
                const ptr_mask = ~@as(usize, ~@as(@TagType(Hint), 0));
                const callback = @intToPtr(Callback, self.data & ptr_mask);
                return (callback)(self, context);
            }
        };
    };
}


