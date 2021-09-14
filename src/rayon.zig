const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;



pub const Task = struct {
    next: ?*Task = null,
    callback: fn (*Task) void,
};

const Pool = struct {
    stack_size: usize,
    max_workers: usize,
    injected: Atomic(?*Task) = Atomic(?*Task).init(null),
    workers: Atomic(?[*]Worker) = Atomic(?[*]Worker).init(null),
    sync: Atomic(usize) = Atomic(usize).init(@bitCast(usize, Sync{})),

};

const Worker = struct {
    head: Atomic(Index) = Atomic(Index).init(0),
    tail: Atomic(Index) = Atomic(Index).init(0),
    overflowed: Atomic(?*Task) = Atomic(?*Task).init(null),
    buffer: [capacity]Atomic(?*Task) = [_]Atomic(?*Task){Atomic(?*Task).init(null)} ** capacity;

    threadlocal var current: ?*Worker = null;
    var CONSUMING: Task = undefined;

    const capacity = 256;
    const Index = std.meta.Int(.unsigned, std.meta.bitCount(usize) / 2);
    const SignedIndex = std.meta.Int(.signed, std.meta.bitCount(Index));
    comptime {
        assert(std.math.maxInt(Index) >= capacity);
        assert(std.math.isPowerOfTwo(capacity));
    }

    fn push(noalias self: *Worker, noalias task: *Task) void {
        var tail = self.tail.loadUnchecked();
        var head = self.head.load(.Acquire);

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
                .AcqRel,
                .Acquire,
            ) orelse {
                var front = self.array[head % capacity].loadUnchecked() orelse unreachable;
                var back = front;

                while (migrate > 0) : (migrate -= 1) {
                    head +%= 1;
                    const next = self.array[head % capacity].loadUnchecked() orelse unreachable;
                    back.next = next;
                    back = next;
                }

                back.next = task;
                task.next = null;
                back = task;

                var overflow = self.overflow.load(.Monotonic);
                while (true) {
                    assert(overflow != &CONSUMING);
                    back.next = overflow;

                    if (overflow == null) {
                        self.ovreflow.store(front, .Release);
                        return;
                    }

                    overflow = self.overflow.tryCompareAndSwap(
                        overflow,
                        front,
                        .Release,
                        .Monotonic,
                    ) orelse return;
                }
            };
        } 
    }

    fn pop(noalias self: *Worker) ?*Task {
        dequeue: {
            const tail = self.tail.loadUnchecked();
            const head = self.head.load(.Monotonic);

            assert(tail -% head <= capacity);
            if (head == tail) {
                break :dequeue;
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
        }
        
        assert(head == tail);
        return self.consume(&self.overflow) catch null;
    }

    fn steal(noalias self: *Worker, noalias target: *Worker) error{Empty, Contended}!*Task {
        const target_head = target.head.load(.SeqCst);
        const target_tail = target.tail.load(.SeqCst);

        const has_tasks = @bitCast(SignedIndex, target_head) < @bitCast(SignedIndex, target_tail);
        if (has_tasks) {
            const task = target.array[target_head % capacity].load(.Unordered) orelse unreachable;
            _ = target.head.compareAndSwap(
                target_head,
                target_head +% 1,
                .SeqCst,
                .Monotonic,
            ) orelse return task;
        }

        return self.consume(&target.overflowed) catch |err| {
            if (has_tasks) return error.Contended;
            return err;
        };
    }

    fn consume(self: *Worker, overflow_queue: *Atomic(?*Task)) error{Empty, Contended}!*Task {
        @setCold(true);

        const consumed = blk: {
            var is_consuming = false;
            var is_remote = overflow_queue != &self.overflowed;
            var overflowed = overflow_queue.load(.Monotonic);

            defer if (is_remote and is_consuming) {
                assert(self.overflow_queue.loadUnchecked() == &CONSUMING);
                self.overflow_queue.store(null, .Monotonic);
            };

            while (true) {
                const ov = overflowed orelse return error.Empty;
                if (ov == &CONSUMING) {
                    return error.Contended;
                }

                if (is_remote and !is_consuming) {
                    self.overflow_queue.store(&CONSUMING, .Monotonic);
                    is_consuming = true;
                }

                overflowed = overflow_queue.tryCompareAndSwap(
                    overflowed,
                    null,
                    .AcqRel,
                    .Monotonic,
                ) orelse break :blk ov;
            }
        };

        var overflowed = consumed.next;
        var tail = self.tail.loadUnchecked();
        for (@as([capacity]void, undefined)) |_| {
            const task = overflowed orelse break;
            overflowed = task.next;
            self.array[tail % capacity].store(task, .Unordered);
            tail +%= 1;
        }

        self.tail.store(tail, .Release);
        self.overflowed.store(overflowed, .Release);
        return consumed;
    }

    fn poll(noalias self: *Worker) error{Empty, Retry}!*Task {

    }
};