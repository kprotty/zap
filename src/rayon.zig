const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;



pub const Task = struct {
    next: ?*Task = null,
    callback: fn (*Task) void,
};

pub const Batch = struct {
    len: usize = 0,
    head: ?*Task = null,
    tail: ?*Task = null,

    pub fn from(batchable: anytype) Batch {
        const task = switch (@TypeOf(batchable)) {
            *Task => batchable,
            Batch => return batchable,
            else => |T| @compileError(@typeName(T) ++ " is not batchable"),
        };

        return Batch{
            .len = 1,
            .head = task,
            .tail = task,
        };
    }

    pub fn push(self: *Batch, batchable: anytype) void {
        const batch = Batch.from(batchable);
        if (batch.len == 0) {
            return;
        }

        if (self.len == 0) {
            self.* = batch;
        } else {
            batch.tail.?.next = self.head;
            self.head = batch.head;
            self.len += batch.len;
        }
    }

    pub fn pop(self: *Batch) ?*Task {
        self.len = std.math.sub(usize, self.len, 1) catch return null;
        const task = self.head orelse unreachable;
        self.head = task.next;
        return task;
    }
};

const Sync = packed struct {
    idle: Count = 0,
    spawned: Count = 0,
    searching: Count = 0,
    shutdown: bool = false,
    padding: Padding = if (std.meta.bitCount(Padding) > 0) 0 else undefined,

    const Count = std.meta.Int(
        .unsigned,
        @divFloor(std.meta.bitCount(usize) - 1, 3),
    );

    const Padding = std.meta.Int(
        .unsigned,
        std.meta.bitCount(usize) - 1 - (std.meta.bitCount(Count) * 3),
    );
};

const Pool = struct {
    stack_size: usize,
    max_workers: usize,
    injected: Queue = .{},
    workers: Atomic(?[*]Worker) = Atomic(?[*]Worker).init(null),
    sync: Atomic(usize) = Atomic(usize).init(@bitCast(usize, Sync{})),

};

const Worker = struct {
    index: usize,
    pool_state: usize,
    xorshift: u32,
    futex: Atomic(u32) = Atomic(u32).init(0),
    buffer: Buffer = .{},

    threadlocal var current: ?*Worker = null;

    var CONSUMING: Task = undefined;

    const IS_SEARCHING: usize = 0b1;

    

    fn run(noalias pool: *Pool, index: usize) void {
        var self = Worker{
            .index = index,
            .xorshift = @as(u32, 0xdeadbeef) + index,
            .pool_state = @ptrToInt(pool) | IS_SEARCHING,
        };

        pool.register(&self, index);
        defer pool.unregister(&self, index);

        const old_current = current;
        current = &self;
        defer current = old_current;


    }

    fn poll(noalias self: *Worker) ?*Task {
        var sync: Sync = undefined;
        var updated: usize = undefined;
        var is_searching = self.pool_state & IS_SEARCHING;
        var pool = @intToPtr(*Pool, self.pool_state & ~IS_SEARCHING);

        defer reset_searching: {
            self.pool_state = @ptrToInt(pool) | @boolToInt(is_searching);
            if (!is_searching) {
                break :reset_searching;
            }

            updated = @bitCast(usize, Sync{ .searching = 1 });
            sync = @bitCast(Sync, pool.sync.fetchSub(updated, .SeqCst));
            assert(sync.searching > 0);
            pool.notify();
        }

        if (self.pop()) |task| {
            return task;
        }

        while (true) {

        }
    }

    fn search(noalias self: *Worker, noalias pool: *Pool) error{Empty, Contended}!*Task {
        const workers = pool.workers.load(.Acquire) orelse unreachable;
        var steal_index =  
    }

    fn push(noalias self: *Worker, noalias pool: *Pool, batch: Batch) void {
        var pushed = batch;
        self.buffer.push(&pushed) catch pool.injected.push(pushed);
    }

    fn pop(noalias self: *Worker, noalias pool: *Pool) error{Empty, Contended}!*Task {
        if (self.buffer.pop()) |task| return task;
        return self.buffer.consume(&pool.injected);
    }
};

const Buffer = struct {
    head: Atomic(Index) = Atomic(Index).init(0),
    tail: Atomic(Index) = Atomic(Index).init(0),
    buffer: [capacity]Atomic(?*Task) = [_]Atomic(?*Task){Atomic(?*Task).init(null)} ** capacity,

    const capacity = 256;
    const Index = std.meta.Int(.unsigned, std.meta.bitCount(usize) / 2);
    const SignedIndex = std.meta.Int(.signed, std.meta.bitCount(Index));
    comptime {
        assert(std.math.maxInt(Index) >= capacity);
        assert(std.math.isPowerOfTwo(capacity));
    }

    fn push(noalias self: *Worker, noalias batch: *Batch) error{Overflowed}!void {
        const overflow = capacity / 2;
        if (batch.len > overflow) {
            return error.Overflowed;
        }

        var tail = self.tail.loadUnchecked();
        var head = self.head.load(.Acquire);

        while (batch.len > 0) {
            var size = tail -% head;
            assert(size <= capacity);

            if (size < capacity) {
                while (size < capacity) : (size += 1) {
                    const task = batch.pop() orelse break;
                    self.array[tail % capacity].store(task, .Unordered);
                    tail +%= 1;
                }
                
                self.tail.store(tail, .Release);
                if (batch.len == 0) {
                    return;
                }

                std.atomic.spinLoopHint();
                head = self.head.load(.Acquire);
                continue;
            }

            head = self.head.tryCompareAndSwap(
                head,
                head +% overflow,
                .AcqRel,
                .Acquire,
            ) orelse {
                var batch: Batch = undefined;
                batch.head = self.array[head % capacity].loadUnchecked();
                batch.tail = batch.head;
                batch.len = overflow;

                var migrate = overflow;
                while (migrate > 0) : (migrate -= 1) {
                    head +%= 1;
                    const next = self.array[head % capacity].loadUnchecked() orelse unreachable;
                    back.next = next;
                    back = next;
                }

                back.next = task;
                back = task;

                batch.push(Batch {
                    .len = overflow,
                    .head = front,
                    .
                })
            };
        } 
    }

    fn pop(self: *Buffer) ?*Task {
        const tail = self.tail.loadUnchecked();
        const head = self.head.load(.Acquire);

        assert(tail -% head <= capacity);
        if (head == tail) {
            return null;
        }

        const new_tail = tail -% 1;
        self.tail.store(new_tail, .SeqCst);
        head = self.head.load(.SeqCst);

        const size = tail -% head;
        assert(size <= capacity);

        const task = self.array[new_tail % capacity].loadUnchecked() orelse unreachable;
        if (size > 1) {
            return task;
        }

        self.tail.store(tail, .Monotonic);
        if (size == 1) {
            _ = self.head.compareAndSwap(
                head,
                tail,
                .SeqCst,
                .Monotonic,
            ) orelse return task;
        }

        return null;
    }

    fn steal(self: *Buffer) error{Empty, Contended}!*Task {
        const target_head = target.head.load(.SeqCst);
        const target_tail = target.tail.load(.SeqCst);

        if (@bitCast(SignedIndex, target_head) >= @bitCast(SignedIndex, target_tail)) {
            return error.Empty;
        }

        const task = target.array[target_head % capacity].load(.Unordered) orelse unreachable;
        if (target.head.compareAndSwap(
            target_head,
            target_head +% 1,
            .SeqCst,
            .Monotonic,
        )) |_| {
            return error.Contended;
        }

        return task;
    }

    fn consume(noalias self: *Buffer, noalias queue: *Queue) error{Empty, Contended}!*Task {
        var consumer = try queue.consume();
        defer consumer.release();

        const task = consumer.pop() orelse {
            return error.Empty;
        };

        const tail = self.tail.loadUnchecked();
        const head = self.head.load(.Acquire);
        
        const size = tail -% head;
        assert(size <= capacity);
        var available = capacity - size;

        var new_tail = tail;
        while (available > 0) : (available -= 1) {
            const migrated = consumer.pop() orelse break;
            self.array[new_tail % capacity].store(migrated, .Unordered);
            new_tail +%= 1;
        }

        self.tail.store(new_tail, .Release);
        return task;
    }
};

const Queue = struct {
    cache: ?*Task = null,
    stack: Atomic(usize) = Atomic(usize).init(0),

    const HAS_CACHE: usize = 0b01;
    const HAS_CONSUMER: usize = 0b10;
    const PTR_MASK = ~(HAS_CACHE | HAS_CONSUMER);
    
    comptime {
        assert(@alignOf(Task) >= ~PTR_MASK + 1);
    }

    fn push(noalias self: *Queue, batch: Batch) void {
        var stack = self.stack.load(.Monotonic);
        while (true) {
            assert(batch.len > 0);
            batch.tail.?.next = @intToPtr(?*Task, stack & PTR_MASK);
            
            stack = self.stack.tryCompareAndSwap(
                stack,
                @ptrToInt(batch.head) | (stack & ~PTR_MASK),
                .Release,
                .Monotonic,
            ) orelse return;
        }
    }

    fn consume(noalias self: *Queue) error{Empty, Contended}!Consumer {
        var stack = self.stack.load(.Monotonic);
        while (true) {
            if (stack & (PTR_MASK | HAS_CACHE) == 0) return error.Empty;
            if (stack & HAS_CONSUMER != 0) return error.Contended;

            var new_stack = stack | HAS_CONSUMER | HAS_CACHE;
            if (stack & HAS_CACHE == 0) {
                assert(stack & PTR_MASK != 0);
                new_stack &= ~PTR_MASK;
            }

            stack = self.stack.tryCompareAndSwap(
                stack,
                new_stack,
                .Acquire,
                .Monotonic,
            ) orelse {
                if (stack & HAS_CACHE == 0) {
                    assert(self.cache == null);
                } else {
                    assert(self.cache != null);
                }

                return Consumer{
                    .queue = self,
                    .cache = self.cache orelse @intToPtr(*Task, stack & PTR_MASK),
                };
            };
        }
    }

    const Consumer = struct {
        queue: *Queue,
        cache: ?*Task,

        fn pop(noalias self: *Consumer) ?*Task {
            const task = self.cache orelse take: {
                var stack = self.queue.stack.load(.Monotonic);
                assert(stack & HAS_CONSUMER != 0);

                if (stack & PTR_MASK == 0) {
                    return null;
                }

                stack = self.queue.stack.swap(HAS_CONSUMER | HAS_CACHE, .Acquire);
                assert(stack & HAS_CONSUMER != 0);
                assert(stack & PTR_MASK != 0);

                break :take @intToPtr(*Task, stack & PTR_MASK);
            };

            self.cache = task.next;
            return task;
        }

        fn release(self: Consumer) void {
            comptime assert(HAS_CACHE == 0b1);
            const has_cache = self.cache != null;
            const remove = HAS_CONSUMER | @bool(has_cache);

            self.queue.cache = self.cache;
            const stack = self.queue.stack.fetchSub(remove, .Release);
            assert(stack & HAS_CONSUMER != 0);
        }
    };
};