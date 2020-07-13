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

            };

            const IdleState = enum(u2) {
                ready = 3,
                waking = 2,
                notified = 1,
                shutdown = 0,
            };

            const MAX_WORKERS = (@as(usize, 1) << (@typeInfo(usize).Int.bits - 10)) - 1;

            workers_active: AtomicUsize,
            idle_queue: AtomicUsize align(CACHE_LINE),
            runq_polling: AtomicUsize align(CACHE_LINE),
            runq_head: *Runnable align(CACHE_LINE),
            runq_tail: *Runnable align(CACHE_LINE),
            runq_next: ?*Runnable,
            next: *Node align (CACHE_LINE),
            scheduler: *Scheduler,
            ref_ptr: [*]Worker,
            ref_len: usize,

            pub fn init(thread_refs: []Thread.Ref) Node {
                var self: Node = undefined;
                self.ref_ptr = thread_refs.ptr;
                self.ref_len = std.math.min(MAX_WORKERS, thread_refs.len);
                return self;
            }

            fn initUsing(
                noalias self: *Node,
                noalias scheduler: *Scheduler,
            ) void {
                var idle_queue: usize = 0;


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
            pub const Ref = extern struct {
                ptr: usize align(4),
            };

            runq_head: AtomicUsize,
            runq_tail: AtomicUsize align(CACHE_LINE),
            runq_next: ?*Runnable,
            runq_buffer: [THREAD_BUFFER]*Runnable align(CACHE_LINE),
            next: usize,
            node: *Node,

        };
    };
}


