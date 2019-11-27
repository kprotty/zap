const Task = struct {
    next: ?*Task,
};

const GlobalQueue = struct {
    lock: std.Mutex,
    head: ?*Task,
    tail: ?*Task,
    size: usize,

    fn push(self: *GlobalQueue, head: *Task, tail: *Task, size: usize) void {
        const held = self.lock.acquire();
        defer held.release();

        if (self.tail) |t| {
            t.next = head;
        }
        self.tail = tail;
        self.head = self.head orelse head;
        self.size += size;
    }
};

/// An SPMC queue which pushes to the tail & pops from the head.
/// The single producer can pop from the head (FIFO) or tail (LIFO).
/// Multiple consumers can `steal()` tasks from the queue while the producer is running.
const LocalQueue = extern struct {
    head: u16,
    tail: u16,
    tasks: [256]*Task,

    /// PRODUCER: Push a task to the queue, overflowing into the global queue
    fn push(self: *LocalQueue, task: *Task, global: *GlobalQueue) void {
        while (true) : (std.SpinLock.yield(1)) {
            const head = @atomicLoad(u16, &self.head, .Acquire);
            const tail = self.tail;
            const size = tail -% head;

            // if local queue isnt full, push to tail
            if (size < self.tasks.len) {
                self.tasks[tail % self.tasks.len] = task;
                @atomicStore(u16, &self.tail, tail +% 1, .Release);
                return;
            }
            
            // local queue is full, prepare to move half of it into global queue
            const migrate = size / 2;
            std.debug.assert(migrate == self.tasks.len / 2);
            _ = @cmpxchgWeak(u16, &self.head, head +% migrate, .Release, .Monotonic) orelse continue;

            // form a linked list of the tasks
            var i: u16 = 0;
            task.next = null;
            self.tasks[(head +% migrate - 1) % self.tasks.len] = task;
            while (i < migrate) : (i += 1) {
                const t = self.tasks[(head +% i) % self.tasks.len];
                t.next = self.tasks[(head +% (i + 1)) % self.tasks.len];
            }

            // submit the linked list of the tasks to the global queue
            const top = self.tasks[head % self.tasks.len];
            global.push(top, task, migrate + 1);
            return;
        }
    }

    /// PRODUCER: Pop a task from the queue FIFO style (from head)
    fn popBack(self: *LocalQueue) ?*Task {
        while (true) : (std.SpinLock.yield(1)) {
            const tail = self.tail;
            const head = @atomicLoad(u16, &self.head, .Acquire);
            if (tail == head) {
                return null;
            }

            const task = self.tasks[head % self.tasks.len];
            _ = @cmpxchgWeak(u16, &self.head, head, head +% 1, .Release, .Monotonic) orelse return task;
        }
    }

    /// PRODUCER: Pop a task from the queue LIFO style (from tail)
    fn popFront(self: *LocalQueue) ?*Task {
        while (true) : (std.SpinLock.yield(1)) {
            const tail = self.tail;
            const head = @atomicLoad(u16, &self.head, .Acquire);
            if (tail == head) {
                return null;
            }

            // manual double-sized cmpxchg which only updates
            // the tail if the head didnt change by a stealer.
            const task = self.tasks[(tail -% 1) % self.tasks.len];
            _ = @cmpxchgWeak(u32,
                @ptrCast(*u32, &self),
                (@as(u32, head) << 16) | @as(u32, tail),
                (@as(u32, head) << 16) | @as(u32, tail -% 1),
                .Release,
                .Monotonic,
            ) orelse return task;
        }
    }

    /// CONSUMER: Steal half the tasks from `other` queue into `self` queue and returns the first
    fn steal(self: *LocalQueue, other: *LocalQueue) ?*Task {
        // only steal when self is empty
        const t = self.tail;
        const h = @atomicLoad(u32, &self.head, .Monotonic);
        std.debug.assert(t == h);

        while (true) : (std.SpinLock.yield(1)) {
            // acquire on both to synchronize with the producer & other stealers
            const head = @atomicLoad(u16, &other.head, .Acquire);
            const tail = @atomicLoad(u16, &other.tail, .Acquire);
            const size = tail -% head;
            if (size == 0) {
                return null;
            }

            // write the tasks locally
            var i: u16 = 0;
            var steal_size = size - (size / 2);
            while (i < steal_size) : (i += 1) {
                const task = other.tasks[(head +% i) % self.tasks.len];
                self.tasks[(t +% i) % self.tasks.len] = task;
            }

            // try and commit the steal (against both head & tail to sync with pop*())
            _ = @cmpxchgWeak(u16, 
                @ptrCast(*u32, other),
                (@as(u32, head) << 16) | @as(u32, tail),
                (@as(u32, head +% steal_size) << 16) | @as(u32, tail),
                .Release,
                .Monotonic,
            ) orelse {
                steal_size -= 1; // returning the last tasks
                if (steal_size != 0) {
                    @atomicStore(u16, &self.tail, t +% steal_size, .Release);
                }
                return self.tasks[(t +% steal_size) % self.tasks.len];
            };
        }
    }
};

