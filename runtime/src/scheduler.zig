const std = @import("std");
const system = @import("./system.zig");
const min = std.math.min;
const max = std.math.max;
const alignForward = std.mem.alignForward;

const CACHE_LINE = 
    if (std.builtin.arch == .x86_64) 64 * 2
    else 64;

pub const Builder = extern struct {
    pub const PoolConfig = extern struct {
        max_threads: usize,
        max_stack_size: usize,
    };

    core: PoolConfig = PoolConfig{
        .max_threads = std.math.maxInt(usize),
        .max_stack_size = 2 * 1024 * 1024,
    },
    blocking: PoolConfig = PoolConfig{
        .max_threads = 64,
        .max_stack_size = 64 * 1024,
    },

    pub const RunError = std.mem.Allocator.Error;

    pub fn run(self: Builder, task: *Task) RunError!void {
        const topology = system.Node.getTopology();
        var max_system_threads: usize = 0;
        for (topology) |numa_node|
            max_system_threads += numa_node.affinity.getCount();
        
        var start_pool: ?*ThreadPool = null;
        defer {
            for (topology) |numa_node| {
                const core_pool = start_pool orelse break;
                const blocking_pool = core_pool.getAdjacentPool().?;
                start_pool = core_pool.pool_next;

                core_pool.deinit();
                blocking_pool.deinit();

                const slots = blocking_pool.getSlots();
                const memory_ptr = @intToPtr([*]align(std.mem.page_size) u8, @ptrToInt(core_pool));
                const memory_len = @ptrToInt(slots.ptr + slots.len) - @ptrToInt(core_pool);
                numa_node.free(memory_ptr[0..memory_len]);
            }
        }
        
        var last_pool: ?*ThreadPool = null;
        var main_pool: ?*ThreadPool = null;
        const main_index = system.nanotime() % topology.len;

        var this = Builder{
            .core = PoolConfig{
                .max_threads = min(max_system_threads, max(1, self.core.max_threads)),
                .max_stack_size = alignForward(max(64 * 1024, self.core.max_stack_size), std.mem.page_size),
            },
            .blocking = PoolConfig{
                .max_threads = min(1024, max(1, self.blocking.max_threads)),
                .max_stack_size = alignForward(max(64 * 1024, self.blocking.max_stack_size), std.mem.page_size),
            },
        };

        var core_threads = this.core.max_threads;
        var blocking_threads = this.blocking.max_threads;

        for (topology) |*numa_node, index| {
            var num_core_threads = std.math.min(core_threads, numa_node.affinity.getCount());
            var num_blocking_threads = blocking_threads;
            if (index == topology.len - 1) {
                num_blocking_threads = this.blocking.max_threads / topology.len;
                core_threads -= num_core_threads;
                blocking_threads -= num_blocking_threads;
            }

            var bytes: usize = 0;
            const core_offset = bytes;
            bytes += @sizeOf(ThreadPool) + (@sizeOf(ThreadPool.Slot) * num_core_threads); 

            bytes = std.mem.alignForward(bytes, @alignOf(ThreadPool));
            const blocking_offset = bytes;
            bytes += @sizeOf(ThreadPool) + (@sizeOf(ThreadPool.Slot) * num_blocking_threads);

            const memory = numa_node.alloc(bytes) orelse return RunError.OutOfMemory;
            const core_pool = @intToPtr(*ThreadPool, @ptrToInt(memory.ptr) + core_offset);
            const blocking_pool = @intToPtr(*ThreadPool, @ptrToInt(memory.ptr) + blocking_offset);

            core_pool.init(numa_node, topology.len, false, PoolConfig{
                .max_threads = num_core_threads,
                .max_stack_size = this.core.max_stack_size,
            });
            blocking_pool.init(numa_node, topology.len, true, PoolConfig{
                .max_threads = num_blocking_threads,
                .max_stack_size = this.blocking.max_stack_size,
            });

            if (start_pool == null)
                start_pool = core_pool;
            if (index == main_index)
                main_pool = core_pool;
            if (last_pool) |last| {
                last.pool_next = core_pool;
                last.getAdjacentPool().?.pool_next = blocking_pool;
            }
            last_pool = core_pool;
        }

        const first_pool = start_pool.?;
        last_pool.?.pool_next = first_pool;

        const pool = main_pool.?;
        pool.push(Task.List.fromTask(task));
        std.debug.assert(pool.tryResumeThread(true));
    }
};

const ThreadPool = extern struct {
    const Slot = extern struct {
        next: usize align(max(4, @alignOf(usize))),
        ptr: usize,
    };

    const IdleState = enum(u2) {
        Ready = 0,
        Waking = 1,
        Notified = 2,
        Stopped = 3,
    };

    const IdleSlot = switch (std.builtin.arch) {
        .i386, .x86_64 => extern struct {
            const DoubleWord = @Type(std.builtin.TypeInfo{
                .Int = std.builtin.TypeInfo.Int{
                    .is_signed = false,
                    .bits = @typeInfo(usize).Int.bits * 2,
                },
            });

            slot_ptr: usize align(@alignOf(DoubleWord)),
            aba_tag: usize,

            fn fromSlotPtr(slot_ptr: usize) IdleSlot {
                return IdleSlot{
                    .slot_ptr = slot_ptr,
                    .aba_tag = 0,
                };
            }

            fn load(
                self: *const IdleSlot,
                comptime ordering: std.builtin.AtomicOrder,
            ) IdleSlot {
                const slot_ptr = @atomicLoad(usize, &self.slot_ptr, ordering);
                const aba_tag = @atomicLoad(usize, &self.aba_tag, .Unordered);
                return IdleSlot{
                    .slot_ptr = slot_ptr,
                    .aba_tag = aba_tag,
                };
            }

            fn getSlotPtr(self: IdleSlot) usize {
                return self.slot_ptr;
            }

            fn compareExchange(
                self: *IdleSlot,
                current: IdleSlot,
                updated_ptr: usize,
                comptime success_order: std.builtin.AtomicOrder,
                comptime failure_order: std.builtin.AtomicOrder,
            ) ?IdleSlot {
                const new_idle_slot = @cmpxchgWeak(
                    DoubleWord,
                    @ptrCast(*DoubleWord, self),
                    @bitCast(DoubleWord, current),
                    @bitCast(DoubleWord, IdleSlot{
                        .slot_ptr = updated_ptr,
                        .aba_tag = current.aba_tag +% 1,
                    }),
                    success_order,
                    failure_order,
                ) orelse return null;
                return @bitCast(IdleSlot, new_idle_slot);
            }
        },
        else => extern struct {
            slot_ptr: usize,

            fn fromSlotPtr(slot_ptr: usize) IdleSlot {
                return IdleSlot{ .slot_ptr = slot_ptr };
            }

            fn load(
                self: *const IdleSlot,
                comptime ordering: std.builtin.AtomicOrder,
            ) IdleSlot {
                return fromSlotPtr(@atomicLoad(usize, &self.slot_ptr, ordering));
            }

            fn getSlotPtr(self: IdleSlot) usize {
                return self.slot_ptr;
            }

            fn compareExchange(
                self: *IdleSlot,
                current: IdleSlot,
                updated_ptr: usize,
                comptime success_order: std.builtin.AtomicOrder,
                comptime failure_order: std.builtin.AtomicOrder,
            ) ?IdleSlot {
                const slot_ptr = @cmpxchgWeak(
                    usize,
                    &self.slot_ptr,
                    current.slot_ptr,
                    updated_ptr,
                    success_order,
                    failure_order,
                ) orelse return null;
                return IdleSlot{ .slot_ptr = slot_ptr };
            }
        },
    };

    idle_queue: IdleSlot align(CACHE_LINE),
    runq_locked: bool align(CACHE_LINE),
    runq_head: *Task align(CACHE_LINE),
    runq_tail: *Task,
    runq_stub: ?*Task,
    max_stack_size: usize,
    pool_next: ?*ThreadPool,
    pool_count: usize,
    numa_node: *system.Node,
    slots_count: usize,
    is_adjacent: bool,
    slots_start: [0]Slot,

    fn init(
        noalias self: *ThreadPool,
        noalias numa_node: *system.Node,
        num_pools: usize,
        is_adjacent: bool,
        config: Builder.PoolConfig,
    ) void {
        self.idle_queue = IdleSlot.fromSlotPtr(0 | @enumToInt(IdleState.Ready));
        self.runq_locked = false;
        self.runq_head = @fieldParentPtr(Task, "next", &self.runq_stub);
        self.runq_tail = @fieldParentPtr(Task, "next", &self.runq_stub);
        self.runq_stub = null;
        self.max_stack_size = config.max_stack_size;
        self.pool_next = null;
        self.pool_count = num_pools;
        self.numa_node = numa_node;
        self.slots_count = config.max_threads;
        self.is_adjacent = is_adjacent;

        for (self.getSlots()) |*slot| {
            slot.* = Slot{
                .next = self.idle_queue.getSlotPtr() & ~@as(usize, 0b11),
                .ptr = 0x0,
            };
            const slot_ptr = @ptrToInt(slot) | @enumToInt(IdleState.Ready);
            self.idle_queue = IdleSlot.fromSlotPtr(slot_ptr);
        }
    }

    fn deinit(self: *ThreadPool) void {
        for (self.getSlots()) |*slot| {
            var thread_handle: ?system.Thread.Handle = null;
            const slot_ptr = @atomicLoad(usize, &slot.ptr, .Acquire);
            if (slot_ptr & 1 != 0) {
                thread_handle = @intToPtr(system.Thread.Handle, slot_ptr & ~@as(usize, 1));
            } else if (@intToPtr(?*Thread, slot_ptr)) |thread| {
                thread_handle = thread.handle.?;
            }
            if (thread_handle) |handle|
                system.Thread.join(handle);
        }

        const runq_stub = @fieldParentPtr(Task, "next", &self.runq_stub);
        std.debug.assert(!@atomicLoad(bool, &self.runq_locked, .Monotonic));
        std.debug.assert(@atomicLoad(*Task, &self.runq_head, .Monotonic) == runq_stub);
    }

    fn getAdjacentPool(self: *ThreadPool) ?*ThreadPool {
        const slots = self.getSlots();
        const end_ptr = @ptrToInt(slots.ptr + slots.len);
        const pool_ptr = std.mem.alignForward(end_ptr, @alignOf(ThreadPool));
        const adjacent_pool = @intToPtr(*ThreadPool, pool_ptr);

        if (self.is_adjacent or !adjacent_pool.is_adjacent)
            return null;
        return adjacent_pool;
    }

    fn getPoolIter(self: *ThreadPool) Iter {
        return Iter{
            .pool = self,
            .count = self.pool_count,
        };
    }

    const Iter = extern struct {
        pool: *ThreadPool,
        count: usize,

        fn next(self: *Iter) ?*ThreadPool {
            if (self.count == 0)
                return null;
            defer self.count -= 1;
            const thread_pool = self.pool;
            self.pool = thread_pool.pool_next.?;
            return thread_pool;
        }
    };

    fn getSlots(self: *ThreadPool) []Slot {
        const ptr = @ptrToInt(self) + @sizeOf(ThreadPool);
        return @intToPtr([*]Slot, ptr)[0..self.slots_count];
    }

    fn getSlotIter(self: *ThreadPool, rng_state: u32) SlotIter {
        const slots = self.getSlots();
        return SlotIter{
            .index = rng_state % slots.len,
            .count = slots.len,
            .slots = slots,
        };
    }

    const SlotIter = struct {
        index: usize,
        count: usize,
        slots: []Slot,

        fn next(self: *SlotIter) ?*Slot {
            if (self.count == 0)
                return null;
            defer self.count -= 1;
            if (self.index >= self.slots.len)
                self.index = 0;
            defer self.index +%= 1;
            return &self.slots[self.index];
        }
    };

    fn resumeThread(self: *ThreadPool) void {
        var thread_pool_iter = self.getPoolIter();
        while (thread_pool_iter.next()) |thread_pool| {
            if (thread_pool.tryResumeThread(false))
                return;
        }
    }

    fn tryResumeThread(self: *ThreadPool, is_main_thread: bool) bool {
        var idle_queue = self.idle_queue.load(.Acquire);
        while (true) {
            const slot_ptr = idle_queue.getSlotPtr();
            switch (@intToEnum(IdleState, @truncate(u2, slot_ptr))) {
                .Ready => {
                    const slot = @intToPtr(?*Slot, slot_ptr & ~@as(usize, 0b11)) orelse return false;
                    idle_queue = self.idle_queue.compareExchange(
                        idle_queue,
                        slot.next | @enumToInt(IdleState.Waking),
                        .Acquire,
                        .Acquire,
                    ) orelse return self.tryResumeWakingSlot(slot, is_main_thread);
                },
                .Waking => {
                    idle_queue = self.idle_queue.compareExchange(
                        idle_queue,
                        slot_ptr | @enumToInt(IdleState.Notified),
                        .Acquire,
                        .Acquire,
                    ) orelse return true;
                },
                .Notified, .Stopped => return false,
            }
        }
    }

    fn tryResumeWakingSlot(
        noalias self: *ThreadPool,
        noalias slot: *Slot,
        is_main_thread: bool,
    ) bool {
        if (@intToPtr(?*Thread, slot.ptr)) |thread| {
            thread.is_waking = true;
            thread.event.notify();
            return true;
        }

        slot.ptr = 0x0;
        slot.next = @ptrToInt(self);
        if (is_main_thread) {
            Thread.run(slot);
            return true;
        }

        if (system.Thread.spawn(
            self.numa_node,
            self.max_stack_size,
            slot,
            Thread.run,
        )) |thread_handle| {
            if (@cmpxchgStrong(
                usize,
                &slot.ptr,
                0x0,
                @ptrToInt(thread_handle) | 1,
                .Release,
                .Acquire,
            )) |thread_ptr| {
                const handle_ptr = &@intToPtr(*Thread, thread_ptr).handle;
                @atomicStore(?system.Thread.Handle, handle_ptr, thread_handle, .Release);
            }
            return true;
        }

        var idle_queue = self.idle_queue.load(.Monotonic);
        while (true) {
            slot.next = idle_queue.getSlotPtr();
            switch (@intToEnum(IdleState, @truncate(u2, slot.next))) {
                .Ready => unreachable,
                .Waking, .Notified => {
                    idle_queue = self.idle_queue.compareExchange(
                        idle_queue,
                        @ptrToInt(slot) | @enumToInt(IdleState.Ready),
                        .Release,
                        .Monotonic,
                    ) orelse return false;
                },
                .Stopped => return false,
            }
        }
    }

    fn finishWaking(
        noalias self: *ThreadPool,
        noalias slot: *Slot,
    ) void {
        var idle_queue = self.idle_queue.load(.Acquire);
        while (true) {
            const slot_ptr = idle_queue.getSlotPtr();
            switch (@intToEnum(IdleState, @truncate(u2, slot_ptr))) {
                .Ready => unreachable,
                .Waking, .Notified => {
                    const next_slot_ptr = @intToPtr(?*Slot, slot_ptr & ~@as(usize, 0b11));
                    const new_slot = blk: {
                        if (next_slot_ptr) |next_slot| {
                            break :blk next_slot.next | @enumToInt(IdleState.Waking);
                        } else {
                            break :blk @enumToInt(IdleState.Ready);
                        }
                    };
                    idle_queue = self.idle_queue.compareExchange(
                        idle_queue,
                        new_slot,
                        .Acquire,
                        .Acquire,
                    ) orelse {
                        const next_slot = next_slot_ptr orelse return;
                        if (!self.tryResumeWakingSlot(next_slot, false)) {
                            var thread_pool_iter = self.getPoolIter();
                            while (thread_pool_iter.next()) |thread_pool| {
                                if (thread_pool != self and thread_pool.tryResumeThread(false))
                                    break;
                            }
                        }
                        return;
                    };
                },
                .Stopped => return,
            }
        }
    }

    fn trySuspendThread(
        noalias self: *ThreadPool,
        noalias slot: *Slot,
    ) IdleState {
        const thread = @intToPtr(?*Thread, slot.ptr) orelse unreachable;
        const was_waking = thread.is_waking;
        var idle_queue = self.idle_queue.load(.Monotonic);

        while (true) {
            const slot_ptr = idle_queue.getSlotPtr();
            const idle_state = @intToEnum(IdleState, @truncate(u2, slot_ptr));

            if (idle_state == .Stopped)
                return IdleState.Stopped;

            var new_idle_state = idle_state;
            if (was_waking) {
                new_idle_state = .Ready;
                std.debug.assert(idle_state != .Ready);
                if (idle_state == .Notified) {
                    idle_queue = self.idle_queue.compareExchange(
                        idle_queue,
                        slot_ptr | @enumToInt(IdleState.Waking),
                        .Monotonic,
                        .Monotonic,
                    ) orelse {
                        thread.is_waking = true;
                        return IdleState.Notified;
                    };
                    continue;
                }
            }

            thread.is_waking = false;
            slot.next = slot_ptr & ~@as(usize, 0b11);
            idle_queue = self.idle_queue.compareExchange(
                idle_queue,
                @ptrToInt(slot) | @enumToInt(new_idle_state),
                .Release,
                .Monotonic,
            ) orelse {
                thread.event.wait();
                if (thread.is_waking)
                    return IdleState.Waking;
                return IdleState.Stopped;
            };
        }
    }

    fn shutdown(self: *ThreadPool) void {
        var idle_queue = self.idle_queue.load(.Acquire);
        while (true) {
            var slot_ptr = idle_queue.getSlotPtr();
            const idle_state = @intToEnum(IdleState, @truncate(u2, slot_ptr));
            if (idle_state == .Stopped)
                return;

            idle_queue = self.idle_queue.compareExchange(
                idle_queue,
                @enumToInt(IdleState.Stopped),
                .Acquire,
                .Acquire,
            ) orelse {
                slot_ptr = slot_ptr & ~@as(usize, 0b11);
                while (@intToPtr(?*Slot, slot_ptr)) |slot| {
                    slot_ptr = slot.next;
                    if (slot.ptr & 1 != 0)
                        continue;
                    if (@intToPtr(?*Thread, slot.ptr)) |thread| {
                        thread.is_waking = false;
                        thread.event.notify();
                    }
                }
                return;
            };
        }
    }

    fn schedule(self: *ThreadPool, list: Task.List) void {
        self.push(list);
        self.resumeThread();
    }

    fn push(self: *ThreadPool, list: Task.List) void {
        if (list.len == 0)
            return;

        const front = list.head.?;
        const back = list.tail.?;
        
        back.next = null;
        const prev = @atomicRmw(*Task, &self.runq_head, .Xchg, back, .AcqRel);
        @atomicStore(?*Task, &prev.next, front, .Release);
    }

    fn pop(self: *ThreadPool) ?*Task {
        var tail = self.runq_tail;
        var next = @atomicLoad(?*Task, &tail.next, .Acquire);
        const runq_stub = @fieldParentPtr(Task, "next", &self.runq_stub);

        if (tail == runq_stub) {
            tail = next orelse return null;
            self.runq_tail = tail;
            next = @atomicLoad(?*Task, &tail.next, .Acquire);
        }

        if (next) |task| {
            self.runq_tail = task;
            return tail;
        }

        const head = @atomicLoad(*Task, &self.runq_head, .Acquire);
        if (head != tail)
            return null;
        
        self.push(Task.List.fromTask(runq_stub));
        self.runq_tail = @atomicLoad(?*Task, &tail.next, .Acquire) orelse return null;
        return tail;
    }
};

const Thread = extern struct {
    runq_pos: usize align(CACHE_LINE),
    runq_buffer: [256]*Task,
    event: system.Signal,
    handle: ?system.Thread.Handle,
    slot: *ThreadPool.Slot,
    pool: *ThreadPool,
    is_waking: bool,

    fn run(slot: *ThreadPool.Slot) void {
        const pool = @intToPtr(*ThreadPool, slot.next);
        pool.numa_node.affinity.bindCurrentThread();

        var self: Thread = Thread{
            .runq_pos = 0,
            .runq_buffer = undefined,
            .event = undefined,
            .handle = null,
            .slot = slot,
            .pool = pool,
            .is_waking = true,
        };

        self.event.init();
        defer self.event.deinit();

        const handle_ptr = @atomicRmw(usize, &slot.ptr, .Xchg, @ptrToInt(&self), .AcqRel);
        if (@intToPtr(?system.Thread.Handle, handle_ptr & ~@as(usize, 1))) |thread_handle|
            @atomicStore(?system.Thread.Handle, &self.handle, thread_handle, .Release);
        defer {
            if (@atomicLoad(?system.Thread.Handle, &self.handle, .Acquire))
            @atomicStore(usize, &slot.ptr, @ptrToInt(thread_handle) | 1, .Release);
        }
        
        var iteration: usize = 0;
        var rng_state: u32 = @truncate(u32, @ptrToInt(&self) ^ @ptrToInt(pool));
        while (true) {

            while (self.poll(pool, slot, &rng_state, iteration)) |task_ptr| {
                iteration +%= 1;
                var next_task: ?*Task = task_ptr;
                var max_direct_yields: usize = 8;
                while (max_direct_yields != 0) : (max_direct_yields -= 1) {
                    const task = next_task orelse break;
                    next_task = task.run(@ptrCast(*Task.Context, &self));
                }
                if (next_task) |task|
                    self.schedule(Task.List.fromTask(task));
            }

            switch (pool.trySuspendThread(slot)) {
                .Ready => unreachable,
                .Waking => std.debug.assert(self.is_waking),
                .Notified => continue,
                .Stopped => break,
            }
        }
    }

    const Index = @Type(std.builtin.TypeInfo{
        .Int = std.builtin.TypeInfo.Int{
            .is_signed = false,
            .bits = @typeInfo(usize).Int.bits / 2,
        },
    });

    fn poll(
        noalias self: *Thread,
        noalias pool: *ThreadPool,
        noalias slot: *ThreadPool.Slot,
        rng_state_ptr: *u32,
        iteration: usize,
    ) ?*Task {
        const new_task = blk: {
            if (!self.is_waking) {
                if (iteration % 61 == 0) {
                    if (self.pollGlobal(pool)) |task|
                        break :blk task;
                }

                if (iteration % 31 == 0) {
                    if (self.pollLocal(.Back)) |task|
                        break :blk task;
                }

                if (self.pollLocal(.Front)) |task|
                    break :blk task;
            }

            var steal_attempts: usize = 4;
            while (steal_attempts != 0) : (steal_attempts -= 1) {
                const rng_state = rng_blk: {
                    var rng = rng_state_ptr.*;
                    rng ^= rng << 13;
                    rng ^= rng >> 17;
                    rng ^= rng << 5;
                    rng_state_ptr.* = rng;
                    break :rng_blk rng;
                };
                
                var thread_pool_iter = pool.getPoolIter();
                while (thread_pool_iter.next()) |thread_pool| {
                    if (self.pollGlobal(thread_pool)) |task|
                        break :blk task;
                    
                    var slot_iter = thread_pool.getSlotIter(rng_state);
                    while (slot_iter.next()) |slot_ptr| {
                        if (slot_ptr == slot or (slot_ptr.ptr & 1 != 0))
                            continue;
                        if (@intToPtr(?*Thread, slot_ptr.ptr)) |target_thread| {
                            if (self.pollSteal(target_thread)) |task|
                                break :blk task;
                        } 
                    }
                }
            }

            return null;
        };

        if (self.is_waking)
            pool.finishWaking(self.slot);
        return new_task;

    }

    fn pollLocal(
        noalias self: *Thread,
        side: Task.List.Side,
    ) ?*Task {
        var pos = @atomicLoad(usize, &self.runq_pos, .Monotonic);
        while (true) {
            var head = @bitCast([2]Index, pos)[0];
            var tail = @bitCast([2]Index, pos)[1];
            if (tail -% head == 0)
                return null;

            const task = switch (side) {
                .Front => blk: {
                    defer head +%= 1;
                    break :blk self.runq_buffer[head % self.runq_buffer.len];
                },
                .Back => blk: {
                    tail -%= 1;
                    break :blk self.runq_buffer[tail % self.runq_buffer.len];
                },
            };

            pos = @cmpxchgWeak(
                usize,
                &self.runq_pos,
                pos,
                @bitCast(usize, [2]Index{ head, tail }),
                .Monotonic,
                .Monotonic,
            ) orelse return task;
        }
    }

    fn pollGlobal(
        noalias self: *Thread,
        noalias pool: *ThreadPool,
    ) ?*Task {
        if (@atomicLoad(bool, &pool.runq_locked, .Monotonic))
            return null;
        if (@cmpxchgStrong(bool, &pool.runq_locked, false, true, .Acquire, .Monotonic) != null)
            return null;
        defer @atomicStore(bool, &pool.runq_locked, false, .Release);

        const pos = @atomicLoad(usize, &self.runq_pos, .Monotonic);
        const head = @bitCast([2]Index, pos)[0];
        const tail = @bitCast([2]Index, pos)[1];

        var new_tail = tail;
        var first_task: ?*Task = null;
        while (new_tail -% head < self.runq_buffer.len) {
            const task = pool.pop() orelse break;
            if (new_tail == tail) {
                first_task = task;
            } else {
                self.runq_buffer[new_tail % self.runq_buffer.len] = task;
                new_tail +%= 1;
            }
        }

        if (new_tail != tail) {
            @atomicStore(
                Index,
                &@ptrCast(*[2]Index, &self.runq_pos)[1],
                new_tail,
                .Release,
            );
        }
        return first_task;
    }

    fn pollSteal(
        noalias self: *Thread,
        noalias target: *Thread,
    ) ?*Task {
        const pos = @atomicLoad(usize, &self.runq_pos, .Monotonic);
        const head = @bitCast([2]Index, pos)[0];
        const tail = @bitCast([2]Index, pos)[1];
        
        var target_pos = @atomicLoad(usize, &target.runq_pos, .Acquire);
        while (true) {
            var target_head = @bitCast([2]Index, target_pos)[0];
            var target_tail = @bitCast([2]Index, target_pos)[1];

            var migrate = switch (target_tail -% target_head) {
                0 => return null,
                1 => 1,
                else => |target_size| target_size >> 2,
            };

            var new_tail = tail;
            var first_task: ?*Task = null;
            while (migrate != 0) : (migrate -= 1) {
                defer target_head +%= 1;
                const task = target.runq_buffer[target_head % target.runq_buffer.len];
                if (first_task == null) {
                    first_task = task;
                } else {
                    self.runq_buffer[new_tail % self.runq_buffer.len] = task;
                    new_tail +%= 1;
                }
            }

            if (@cmpxchgWeak(
                usize,
                &target.runq_pos,
                target_pos,
                @bitCast(usize, [2]Index{ target_head, target_tail }),
                .Acquire,
                .Acquire,
            )) |new_target_pos| {
                target_pos = new_target_pos;
                continue;
            }

            if (new_tail != tail) {
                @atomicStore(
                    Index,
                    &@ptrCast(*[2]Index, &self.runq_pos)[1],
                    new_tail,
                    .Release,
                );
            }
            return first_task;
        }
    }

    fn schedule(self: *Thread, task_list: Task.List) void {
        var list = task_list;
        if (list.len == 0)
            return;

        const pool = self.pool;
        if (list.len > 1)
            return pool.schedule(list);

        const task = list.pop().?;
        const side = switch (task.getPriority()) {
            .Low => return pool.schedule(list),
            .Normal => Task.List.Side.Back,
            .High => Task.List.Side.Front,
        };

        const pos = @atomicLoad(usize, &self.runq_pos, .Monotonic);
        var head = @bitCast([2]Index, pos)[0];
        var tail = @bitCast([2]Index, pos)[1];
        
        while (true) {
            if (tail -% head < self.runq_buffer.len) {
                switch (side) {
                    .Front => {
                        self.runq_buffer[(head -% 1) % self.runq_buffer.len] = task;
                        head = @cmpxchgWeak(
                            Index,
                            &@ptrCast(*[2]Index, &self.runq_pos)[0],
                            head,
                            head -% 1,
                            .Release,
                            .Monotonic,
                        ) orelse return pool.resumeThread();
                        continue;
                    },
                    .Back => {
                        self.runq_buffer[tail % self.runq_buffer.len] = task;
                        @atomicStore(
                            Index,
                            &@ptrCast(*[2]Index, &self.runq_pos)[1],
                            tail +% 1,
                            .Release,
                        );
                        return pool.resumeThread();
                    },
                }
            }

            var migrate: Index = self.runq_buffer.len / 2;
            var new_tail = tail -% migrate;
            if (@cmpxchgWeak(
                usize,
                &self.runq_pos,
                @bitCast(usize, [2]Index{ head, tail }),
                @bitCast(usize, [2]Index{ head, new_tail }),
                .Monotonic,
                .Monotonic,
            )) |new_pos| {
                head = @bitCast([2]Index, new_pos)[0];
                continue;
            }

            var overflow_list = Task.List{};
            while (migrate != 0) : (migrate -= 1) {
                const overflow_task = self.runq_buffer[new_tail % self.runq_buffer.len];
                overflow_list.push(.Front, overflow_task);
                new_tail +%= 1;
            }

            switch (side) {
                .Front => {
                    pool.push(overflow_list);
                    tail -%= migrate;
                    continue;
                },
                .Back => {
                    overflow_list.push(.Back, task);
                    pool.schedule(list);
                    return;
                },
            }
        }
    }
};

pub const Task = extern struct {
    next: ?*Task,
    state: usize,

    pub const RunFn = fn(*Task, *Context) callconv(.C) ?*Task;

    pub const Priority = enum(u2) {
        Low = 0,
        Normal = 1,
        High = 2,
    };

    pub fn init(
        priority: Priority,
        run_fn: RunFn,
    ) Task {
        comptime std.debug.assert(@alignOf(RunFn) >= 4);
        return Task{
            .next = null,
            .state = @ptrToInt(run_fn) | @enumToInt(priority),
        };
    }

    pub fn getPriority(self: Task) Priority {
        return @intToEnum(Priority, @truncate(u2, self.state));
    }

    pub fn run(self: *Task, context: *Context) ?*Task {
        const run_fn = @intToPtr(RunFn, self.state & ~@as(usize, 0b11));
        return (run_fn)(self, context);
    }

    pub const Context = extern struct {
        _align: [1]Thread = undefined,

        fn getThread(self: *Context) *Thread {
            return @intToPtr(*Thread, @ptrToInt(self));
        }

        pub fn schedule(self: *Context, list: List) void {
            return self.getThread().schedule(list);   
        }

        pub fn iterTopology(self: *Context) Topology.Iter {
            return Topology.Iter{
                .pool_iter = self.getThread().pool.getPoolIter(),
            };
        }
        
        pub const Topology = extern struct {
            numa_node: *system.Node,
            pool_config: Builder.PoolConfig,

            pub const Iter = extern struct {
                pool_iter: ThreadPool.Iter,

                pub fn next(self: *Iter, topology: *Topology) bool {
                    const thread_pool = self.pool_iter.next() orelse return false;
                    topology.* = .{
                        .numa_node = thread_pool.numa_node,
                        .pool_config = .{
                            .max_stack_size = thread_pool.max_stack_size,
                            .max_threads = thread_pool.slots_count,
                        },
                    };
                    return true;
                }
            };
        };

        pub fn shutdown(self: *Context) void {
            var pool_iter: ThreadPool.Iter = self.getThread().pool.getPoolIter();
            while (pool_iter.next()) |thread_pool| {
                thread_pool.shutdown();
            }
        }
    };

    pub const List = extern struct {
        pub const Side = enum {
            Front,
            Back,
        };

        head: ?*Task = null,
        tail: ?*Task = null,
        len: usize = 0,

        pub fn fromTask(task: *Task) List {
            var list = List{};
            list.push(.Front, task);
            return list;
        }

        pub fn push(
            noalias self: *List,
            side: Side,
            noalias task: *Task,
        ) void {
            self.len += 1;
            switch (side) {
                .Front => {
                    task.next = self.head;
                    if (self.tail == null)
                        self.tail = task;
                    self.head = task;
                },
                .Back => {
                    task.next = null;
                    if (self.head == null)
                        self.head = task;
                    if (self.tail) |tail|
                        tail.next = task;
                    self.tail = task;
                }
            }
        }

        pub fn pop(self: *List) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            if (self.head == null)
                self.tail = null;
            self.len -= 1;
            return task;
        }
    };
};