const std = @import("std");
const builtin = @import("builtin");

const zio = @import("../../zio/zio.zig");
const zuma = @import("../../zuma/zuma.zig");
const zync = @import("../../zync/zync.zig");

// Based on golangs NUMA aware scheduler design:
// https://docs.google.com/document/u/0/d/1d3iI2QWURgDIsSR6G2275vMeQ_X7w-qxM2Vp7iGwwuM/pub#Scheduling
pub const Loop = struct {
    nodes: []*Node,

    pub fn default() !@This() {

    }

    pub fn run(self: *@This(), comptime function: var, args: ...) !void {

    }
};

pub const Node = struct {
    loop: *Loop,
    tick: u64,
    poller: zio.Event.Poller,

    workers: []*Worker,
    idle_workers: usize,
    thread_cache: Thread.Cache,
    run_queue: Worker.GlobalQueue,
};

const Thread = struct {
    next: ?*Thread,
    worker: *Worker,

    pub const Cache = struct {

    };
};

const Worker = struct {
    pub threadlocal var current: ?*Worker = null;

    pub const Task = struct {
        next: ?*Task,
        frame: anyframe,
    };

    tick: u64,
    node: *Node,
    next: ?*Task,
    thread: *Thread,
    run_queue: LocalQueue,

    pub const GlobalQueue = struct {

        pub fn putMany(self: *@This(), task: *Task, count: usize) void {

        }
    };

    pub const LocalQueue = struct {
        const SIZE = 256;

        head: zync.CachePadded(zync.Atomic(usize)),
        tail: zync.CachePadded(zync.Atomic(usize)),
        tasks: [SIZE]*Task,

        pub fn init(self: *@This()) void {
            self.steal_pos = 0;
            self.head.value.set(0);
            self.tail.value.set(0);
        }

        pub fn size(self: *const @This()) usize {
            // Ensure consistency of both head and tail before observing
            while (true) {
                const head = self.head.value.load(.Relaxed);
                const tail = self.tail.value.load(.Relaxed);
                if (tail == self.tail.value.load(.Acquire))
                    return tail - head;
            }
        }

        pub fn put(self: *@This(), task: *Task) void {
            const node = @fieldParentPtr(Worker, "run_queue", self);
            while (true) {
                // fast-path: Acquire synchronizes with consumers & Release makes it consumable
                const head = self.head.value.load(.Acquire);
                const tail = self.tail.value.get();
                if (tail - head < SIZE) {
                    self.tasks[tail % SIZE] = task;
                    self.tail.value.store(tail +% 1, .Release);
                    return;
                }

                // slow-path: queue is full, try and move half of it to the global queue & retry
                std.debug.assert(tail - head == SIZE);
                var batch: [(SIZE / 2) + 1]*Task = undefined;
                for (batch) |*task_ref, index|
                    task_ref.* = self.tasks[(head +% index) % SIZE];
                if (self.head.value.compareSwap(head, head + batch.len, .Acquire, .Relaxed)) |_|
                    continue; // failed to steal half of the queue, retry 

                // convert all the tasks in the batch into a linked list and submit it to the global queue
                // after that, retry putting into local queue as there should be space now
                task.next = null;
                batch[SIZE] = task;
                for (batch[0..SIZE]) |*task_ref, index|
                    task_ref.next = batch[index + 1];
                node.run_queue.putMany(batch[0], batch.len);
            }
        }

        pub fn get(self: *@This(), global_queue: *GlobalQueue) ?*Task {
            const node = @fieldParentPtr(Worker, "run_queue", self).node;
            retry: while (true) {
                // fast-path: non-empty queue (sync with consumers & commit consume)
                const head = self.head.value.load(.Acquire);
                const tail = self.tail.value.get();
                if (tail != head) {
                    const task = self.tasks[head % SIZE];
                    if (self.head.value.compareSwap(head, head + 1, .Release, .Relaxed) == null)
                        return task;
                    continue; // the queue isnt empty, so retry
                }

                // slow path: empty queue. try stealing from others in the order of
                // - run_queue of current node
                // - run_queue of workers on the current node
                // - run_queue of remote nodes
                // - run_queue of workers on remote nodes
                const rng = std.rand.DefaultPrng.init(@ptrToInt(self) ^ head * tail);
                for ([_]void{{}} ** 4) {
                    // TODO:
                }
            }
        }
    };
};