const std = @import("std");

/// A Task is a separate unit of execution in the executor.
pub const Task = extern struct {
    next: ?*Task = undefined,
    runnable: usize,

    pub fn init(frame: anyframe) Task {
        return Task{ .runnable = @ptrToInt(frame) };
    }

    pub const Callback = fn(*Task, *Worker) callconv(.C) void; 

    pub fn initCallback(callback: Callback) Task {
        return Task{ .runnable = @ptrToInt(callback) | 1 };
    }

    /// Executes either the function or async frame initiated with the task.
    /// Requires a worker passed in for callbacks to avoid thread local accesses.
    pub fn execute(self: *Task, worker: *Worker) void {
        // Given that tasks executed often (especially in a non-blocking scheduler)
        // this is a hot path so remove the @intToPtr() checks if it generates them.
        @setRuntimeSafety(false);

        const runnable = self.runnable;
        if (runnable & 1 != 0) {
            const callback = @intToPtr(Callback, runnable & ~@as(usize, 1));
            return (callback)(self, worker);
        }

        const frame = @intToPtr(anyframe, runnable);
        resume frame;
    }

    /// A Batch is an ordered set of Tasks that are generally scheduled together
    pub const Batch = extern struct {
        head: ?*Task = null,
        tail: *Task = undefined,
        
        pub fn from(task: *Task) Batch {
            task.next = null;
            
            return Batch{
                .head = task,
                .tail = task,
            };
        }

        pub fn isEmpty(self: Batch) bool {
            return self.head == null;
        }

        pub fn push(self: *Batch, task: *Task) void {
            return self.pushMany(Batch.from(task));
        }

        pub fn pushMany(self: *Batch, other: Batch) void {
            if (self.isEmpty()) {
                self.* = other;
            } else if (!other.isEmpty()) {
                self.tail.next = other.head;
                self.tail = other.tail;
            }
        }

        pub fn pushFront(self: *Batch, task: *Task) void {
            return self.pushFrontMany(Batch.from(task));
        }

        pub fn pushFrontMany(self: *Batch, other: Batch) void {
            if (self.isEmpty()) {
                self.* = other;
            } else if (!other.isEmpty()) {
                other.tail.next = self.head;
                self.head = other.head;
            }
        }
    }
};

pub const Worker = struct {
    run_queue: BoundedQueue = BoundedQueue{},
    run_queue_lifo: ?*Task = null,
    run_queue_overflow: UnboundedQueue,
};

pub const Scheduler = struct {
    run_queue: UnboundedQueue,
};

/// A queue of tasks with no upper bound.
/// This is an adaptation of Dmitry Vyukov's Intrusive Unbounded MPSC Queue.
/// http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
const UnboundedQueue = struct {
    is_popping: bool,
    head: *Task,
    tail: *Task,
    stub: Task,

    fn init(self: *UnboundedQueue) void {
        self.is_popping = false;
        self.head = &self.stub;
        self.tail = &self.stub;
        self.stub.next = null;
    }

    fn isEmpty(self: *const UnboundedQueue) bool {
        const head = @atomicLoad(*Task, &self.head, .Acquire);
        return head == &self.stub;
    }

    fn push(self: *UnboundedQueue, batch: Task.Batch) void {
        if (batch.isEmpty()) {
            return;
        }

        // update the end of the unbounded queue with the end of our batch
        const prev = @atomicRmw(*Task, &self.head, .Xchg, batch.tail, .AcqRel);
        
        // then link the previous end of the unbounded queue to the beginning of our batch
        // effectively enqueueing our batch in a FIFO fashion.
        //
        // Given these two operations are not done atomically together,
        // The unbounded queue could potentially be observed in an invalid state
        // If this thread is preempted before this store underneath is completed.
        //
        // The state being that theres a new unbounded queue end, 
        // but they aren't reachable by traversing from the start of the queue
        // since it hasn't been linked up yet. 
        @atomicStore(?*Task, &prev.next, batch.head, .Release);
    }

    fn tryAcquire(self: *UnboundedQueue) ?Popper {
        // check if the queue is empty before trying to do a synchronized 
        // operation to take ownership of the consumer queue end.
        if (self.isEmpty()) {
            return null;
        }

        // Try to acquire ownership of the consumer side of the queue
        if (@atomicRmw(bool, &self.is_popping, .Xchg, true, .Acquire)) {
            return null;
        }

        // The caller now has ownership of the consumer end of the queue
        return Poller{ .queue = self };
    }

    const Popper = struct {
        queue: *UnboundedQueue,

        // must be called when the Popper owner is done popping tasks
        // as it releases ownership of the consumer side so others can consume.
        fn deinit(self: *Popper) void {
            @atomicStore(bool, &self.queue.is_popping, false, .Release);
            self.* = undefined;
        }

        fn pop(self: *Popper) ?*Task {
            const stub = &self.queue.stub;
            var tail = self.queue.tail;
            var next = @atomicLoad(?*Task, &tail.next, .Acquire);

            // Skip the stub task if we come across it
            // as its not a real task & only there for the producer.
            if (tail == stub) {
                tail = next orelse return null;
                self.queue.tail = tail;
                next = @atomicLoad(?*Task, &tail.next, .Acquire);
            }

            if (next) |new_tail| {
                self.queue.tail = new_tail;
                return tail;
            }

            // The unbounded queue is now assumed to be empty.
            // Check if the queue is in an inconsistent state as described in `push()`.
            const head = @atomicLoad(*Task, &self.queue.head, .Acquire);
            if (head != tail) {
                return null;
            }

            // We need to push the stub back to the queue when empty for the producer
            // which enables it to assume that theres always a valid tail.
            const stub_batch = Task.Batch.from(stub);
            self.push(stub_batch);

            next = @atomicLoad(?*Task, &tail.next, .Acquire);
            if (next) |new_tail| {
                self.queue.tail = new_tail;
                return tail;
            }

            return null;
        }
    };
};

/// A queue of tasks with an upper bound.
/// This is an adaptation of Golang's SPMC P-worker run queues.
/// https://github.com/golang/go/blob/afe7c8d0b25f26f0abd749ca52c7e1e7dfdee8cb/src/runtime/proc.go#L5613-L5859
const BoundedQueue = struct {

};