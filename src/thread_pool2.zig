const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;
const ThreadPool = @This();

stack_size: u32,
max_threads: u16,
queue: Node.Queue = .{},
join_event: Event = .{},
idle_event: Event = .{},
sync: Atomic(u32) = Atomic(u32).init(0),
threads: Atomic(?*Thread) = Atomic(?*Thread).init(null),

const Sync = packed struct {
    idle: u10 = 0,
    spawned: u10 = 0,
    stealing: u10 = 0,
    padding: u1 = 0,
    shutdown: bool = false,
};

pub const Config = struct {
    max_threads: u16,
    stack_size: u32 = (std.Thread.SpawnConfig{}).stack_size,
};

pub fn init(config: Config) ThreadPool {
    return .{
        .max_threads = std.math.max(1, config.max_threads),
        .stack_size = std.math.max(std.mem.page_size, config.stack_size),
    };
}

pub fn deinit(self: *ThreadPool) void {
    self.join();
    self.* = undefined;
}

/// A Task represents the unit of Work / Job / Execution that the ThreadPool schedules.
/// The user provides a `callback` which is invoked when the *Task can run on a thread.
pub const Task = struct {
    node: Node = .{},
    callback: fn (*Task) void,
};

/// An unordered collection of Tasks which can be submitted for scheduling as a group.
pub const Batch = struct {
    len: usize = 0,
    head: ?*Task = null,
    tail: ?*Task = null,

    /// Create a batch from a single task. 
    pub fn from(task: *Task) Batch {
        return Batch{
            .len = 1,
            .head = task,
            .tail = task,
        };
    }

    /// Another batch into this one, taking ownership of its tasks.
    pub fn push(self: *Batch, batch: Batch) void {
        if (batch.len == 0) return;
        if (self.len == 0) {
            self.* = batch;
        } else {
            self.tail.?.node.next = if (batch.head) |h| &h.node else null;
            self.tail = batch.tail;
            self.len += batch.len;
        }
    }
};

/// Schedule a batch of tasks to be executed by some thread on the thread pool.
pub noinline fn schedule(self: *ThreadPool, batch: Batch) void {
    // Sanity check
    if (batch.len == 0) {
        return;
    }

    // Extract out the Node's from the Tasks
    var list = Node.List{
        .head = &batch.head.?.node,
        .tail = &batch.tail.?.node,
    };

    // Push the task Nodes to the most approriate queue
    if (Thread.current) |thread| {
        thread.buffer.push(&list) catch thread.queue.push(list);
    } else {
        self.queue.push(list);
    }
    
    const sync = @bitCast(Sync, self.sync.load(.Monotonic));
    if (sync.shutdown) return;
    if (sync.stealing > 0) return;
    if (sync.idle == 0 and sync.spawned == self.max_threads) return;
    return self.notify();
}

noinline fn notify(self: *ThreadPool) void {
    var sync = @bitCast(Sync, self.sync.load(.Monotonic));
    while (true) {
        if (sync.shutdown) return;
        if (sync.stealing != 0) return;

        var new_sync = sync;
        new_sync.stealing = 1;
        if (sync.idle > 0) {
            // the thread will decrement idle on its own
        } else if (sync.spawned < self.max_threads) {
            new_sync.spawned += 1;
        } else {
            return;
        }

        sync = @bitCast(Sync, self.sync.tryCompareAndSwap(
            @bitCast(u32, sync),
            @bitCast(u32, new_sync),
            .SeqCst,
            .Monotonic,
        ) orelse {
            if (sync.idle > 0)
                return self.idle_event.notify();
            
            assert(sync.spawned < self.max_threads);
            const spawn_config = std.Thread.SpawnConfig{ .stack_size = self.stack_size };
            const thread = std.Thread.spawn(spawn_config, Thread.run, .{self}) catch @panic("failed to spawn a thread");
            thread.detach();
            return;
        });
    }
}

/// Marks the thread pool as shutdown
pub noinline fn shutdown(self: *ThreadPool) void {
    var sync = @bitCast(Sync, self.sync.load(.Monotonic));
    while (!sync.shutdown) {
        var new_sync = sync;
        new_sync.shutdown = true;
        
        sync = @bitCast(Sync, self.sync.tryCompareAndSwap(
            @bitCast(u32, sync),
            @bitCast(u32, new_sync),
            .SeqCst,
            .Monotonic,
        ) orelse {
            self.idle_event.shutdown();
            return;
        });
    }
}

noinline fn register(self: *ThreadPool, thread: *Thread) void {
    var threads = self.threads.load(.Monotonic);
    while (true) {
        thread.next = threads;
        threads = self.threads.tryCompareAndSwap(
            threads,
            thread,
            .Release,
            .Monotonic,
        ) orelse break;
    }
}

noinline fn unregister(self: *ThreadPool, thread: *Thread) void {
    const one_spawned = @bitCast(u32, Sync{ .spawned = 1 });
    const sync = @bitCast(Sync, self.sync.fetchSub(one_spawned, .SeqCst));

    assert(sync.spawned > 0);
    if (sync.spawned == 1) {
        self.join_event.notify();
    }

    thread.join_event.wait();
    if (thread.next) |next| {
        next.join_event.notify();
    }
}

noinline fn join(self: *ThreadPool) void {
    self.join_event.wait();
    if (self.threads.load(.Acquire)) |thread| {
        thread.join_event.notify();
    }
}

const Thread = struct {
    pool: *ThreadPool,
    next: ?*Thread = null,
    stealing: bool = true,
    target: ?*Thread = null,
    join_event: Event = .{},
    buffer: Node.Buffer = .{},
    queue: Node.Queue = .{},

    threadlocal var current: ?*Thread = null;

    fn run(thread_pool: *ThreadPool) void {
        var self = Thread{ .pool = thread_pool };
        current = &self;

        self.pool.register(&self);
        defer self.pool.unregister(&self);

        while (true) {
            const node = self.poll() catch break;
            const task = @fieldParentPtr(Task, "node", node);
            (task.callback)(task);
        }
    }

    fn poll(self: *Thread) error{Shutdown}!*Node {
        defer if (self.stealing) {
            const one_stealing = @bitCast(u32, Sync{ .stealing = 1 });
            const sync = @bitCast(Sync, self.pool.sync.fetchSub(one_stealing, .SeqCst));

            // assert(sync.stealing > 0);
            if (sync.stealing == 0) {
                std.debug.warn("{} resetspinning(): {}\n", .{std.Thread.getCurrentId(), sync});
                unreachable;
            }

            self.stealing = false;
            self.pool.notify();
        };

        if (self.buffer.pop()) |node|
            return node;

        while (true) {
            if (self.buffer.consume(&self.queue)) |result|
                return result.node;

            if (self.buffer.consume(&self.pool.queue)) |result|
                return result.node;

            if (!self.stealing) blk: {
                var sync = @bitCast(Sync, self.pool.sync.load(.Monotonic));
                if ((@as(u32, sync.stealing) * 2) >= (sync.spawned - sync.idle))
                    break :blk;

                const one_stealing = @bitCast(u32, Sync{ .stealing = 1 });
                sync = @bitCast(Sync, self.pool.sync.fetchAdd(one_stealing, .SeqCst));
                assert(sync.stealing < sync.spawned);
                self.stealing = true;
            }

            if (self.stealing) {
                var attempts: u8 = 4;
                while (attempts > 0) : (attempts -= 1) {
                    var num_threads: u16 = @bitCast(Sync, self.pool.sync.load(.Monotonic)).spawned;
                    while (num_threads > 0) : (num_threads -= 1) {
                        const thread = self.target orelse self.pool.threads.load(.Acquire) orelse unreachable;
                        self.target = thread.next;

                        if (self.buffer.consume(&thread.queue)) |result|
                            return result.node;

                        if (self.buffer.steal(&thread.buffer)) |result|
                            return result.node;
                    }
                }
            }

            if (self.buffer.consume(&self.pool.queue)) |result|
                return result.node;

            var update = @bitCast(u32, Sync{ .idle = 1 });
            if (self.stealing) {
                update -%= @bitCast(u32, Sync{ .stealing = 1 });
            }

            var sync = @bitCast(Sync, self.pool.sync.fetchAdd(update, .SeqCst));
            //std.debug.print("\nwait {}({}):{}\n\t\t{}\n", .{std.Thread.getCurrentId(), self.stealing, sync, @bitCast(Sync, @bitCast(u32, sync) +% update)});
            assert(sync.idle < sync.spawned);
            if (self.stealing) assert(sync.stealing <= sync.spawned);
            self.stealing = false;

            update = @bitCast(u32, Sync{ .idle = 1 });
            if (self.canSteal()) {
                update -%= @bitCast(u32, Sync{ .stealing = 1 });
                self.stealing = true;
            } else {
                self.pool.idle_event.wait();
            }

            sync = @bitCast(Sync, self.pool.sync.fetchSub(update, .SeqCst));
            //std.debug.print("\nwake {}({}):{}\n\t\t{}\n", .{std.Thread.getCurrentId(), self.stealing, sync, @bitCast(Sync, @bitCast(u32, sync) -% update)});
            assert(sync.idle <= sync.spawned);
            if (self.stealing) assert(sync.stealing < sync.spawned);

            self.stealing = !sync.shutdown;
            if (!self.stealing) return error.Shutdown;
            continue;
        }
    }

    fn canSteal(self: *const Thread) bool {
        if (self.queue.canSteal()) 
            return true;

        if (self.pool.queue.canSteal())
            return true;

        var num_threads: u16 = @bitCast(Sync, self.pool.sync.load(.Monotonic)).spawned;
        var threads: ?*Thread = null;
        while (num_threads > 0) : (num_threads -= 1) {
            const thread = threads orelse self.pool.threads.load(.Acquire) orelse unreachable;
            threads = thread.next;

            if (thread.queue.canSteal())
                return true;

            if (thread.buffer.canSteal())
                return true;
        }

        return false;
    }
};

/// Linked list intrusive memory node and lock-free data structures to operate with it
const Node = struct {
    next: ?*Node = null,

    /// A linked list of Nodes
    const List = struct {
        head: *Node,
        tail: *Node,
    };

    /// An unbounded multi-producer-(non blocking)-multi-consumer queue of Node pointers.
    const Queue = struct {
        stack: Atomic(usize) = Atomic(usize).init(0),
        cache: ?*Node = null,

        const HAS_CACHE: usize = 0b01;
        const IS_CONSUMING: usize = 0b10;
        const PTR_MASK: usize = ~(HAS_CACHE | IS_CONSUMING);

        comptime {
            assert(@alignOf(Node) >= ((IS_CONSUMING | HAS_CACHE) + 1));
        }

        noinline fn push(noalias self: *Queue, list: List) void {
            var stack = self.stack.load(.Monotonic);
            while (true) {
                // Attach the list to the stack (pt. 1)
                list.tail.next = @intToPtr(?*Node, stack & PTR_MASK);

                // Update the stack with the list (pt. 2).
                // Don't change the HAS_CACHE and IS_CONSUMING bits of the consumer.
                var new_stack = @ptrToInt(list.head);
                assert(new_stack & ~PTR_MASK == 0);
                new_stack |= (stack & ~PTR_MASK);

                // Push to the stack with a release barrier for the consumer to see the proper list links.
                stack = self.stack.tryCompareAndSwap(
                    stack,
                    new_stack,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }
        }

        fn canSteal(self: *const Queue) bool {
            const stack = self.stack.load(.Monotonic);
            if (stack & IS_CONSUMING != 0) return false;
            if (stack & (HAS_CACHE | PTR_MASK) == 0) return false;
            return true;
        }

        fn tryAcquireConsumer(self: *Queue) error{Empty, Contended}!?*Node {
            var stack = self.stack.load(.Monotonic);
            while (true) {
                if (stack & IS_CONSUMING != 0)
                    return error.Contended; // The queue already has a consumer.
                if (stack & (HAS_CACHE | PTR_MASK) == 0)
                    return error.Empty; // The queue is empty when there's nothing cached and nothing in the stack.

                // When we acquire the consumer, also consume the pushed stack if the cache is empty.
                var new_stack = stack | HAS_CACHE | IS_CONSUMING;
                if (stack & HAS_CACHE == 0) {
                    assert(stack & PTR_MASK != 0);
                    new_stack &= ~PTR_MASK;
                }

                // Acquire barrier on getting the consumer to see cache/Node updates done by previous consumers
                // and to ensure our cache/Node updates in pop() happen after that of previous consumers.
                stack = self.stack.tryCompareAndSwap(
                    stack,
                    new_stack,
                    .Acquire,
                    .Monotonic,
                ) orelse return self.cache orelse @intToPtr(*Node, stack & PTR_MASK);
            }
        }

        fn releaseConsumer(noalias self: *Queue, noalias consumer: ?*Node) void {
            // Stop consuming and remove the HAS_CACHE bit as well if the consumer's cache is empty.
            // When HAS_CACHE bit is zeroed, the next consumer will acquire the pushed stack nodes.
            var remove = IS_CONSUMING;
            if (consumer == null)
                remove |= HAS_CACHE;

            // Release the consumer with a release barrier to ensure cache/node accesses
            // happen before the consumer was released and before the next consumer starts using the cache.
            self.cache = consumer;
            const stack = self.stack.fetchSub(remove, .Release);
            assert(stack & remove != 0);
        }

        fn pop(noalias self: *Queue, noalias consumer_ref: *?*Node) ?*Node {
            // Check the consumer cache (fast path)
            if (consumer_ref.*) |node| {
                consumer_ref.* = node.next;
                return node;
            }

            // Load the stack to see if there was anything pushed that we could grab.
            var stack = self.stack.load(.Monotonic);
            assert(stack & IS_CONSUMING != 0);
            if (stack & PTR_MASK == 0) {
                return null;
            }

            // Nodes have been pushed to the stack, grab then with an Acquire barrier to see the Node links.
            stack = self.stack.swap(HAS_CACHE | IS_CONSUMING, .Acquire);
            assert(stack & IS_CONSUMING != 0);
            assert(stack & PTR_MASK != 0);
            
            const node = @intToPtr(*Node, stack & PTR_MASK);
            consumer_ref.* = node.next;
            return node;
        }
    };

    /// A bounded single-producer, multi-consumer ring buffer for node pointers.
    const Buffer = struct {
        head: Atomic(Index) = Atomic(Index).init(0),
        tail: Atomic(Index) = Atomic(Index).init(0),
        array: [capacity]Atomic(*Node) = undefined,

        const Index = u32;
        const capacity = 256; // Appears to be a pretty good trade-off in space vs contended throughput
        comptime {
            assert(std.math.maxInt(Index) >= capacity);
            assert(std.math.isPowerOfTwo(capacity));
        }

        noinline fn push(noalias self: *Buffer, noalias list: *List) error{Overflow}!void {
            var head = self.head.load(.Monotonic);
            var tail = self.tail.loadUnchecked(); // we're the only thread that can change this
            
            while (true) {
                var size = tail -% head;
                assert(size <= capacity);
                
                // Push nodes from the list to the buffer if it's not empty..
                if (size < capacity) {
                    var nodes: ?*Node = list.head;
                    while (size < capacity) : (size += 1) {
                        const node = nodes orelse break;
                        nodes = node.next;

                        // Array written atomically with weakest ordering since it could be getting atomically read by steal().
                        self.array[tail % capacity].store(node, .Unordered);
                        tail +%= 1;
                    }

                    // Release barrier synchronizes with Acquire loads for steal()ers to see the array writes.
                    self.tail.store(tail, .Release);

                    // Update the list with the nodes we pushed to the buffer and try again if there's more.
                    list.head = nodes orelse return;
                    std.atomic.spinLoopHint();
                    head = self.head.load(.Monotonic);
                    continue;
                }

                // Try to steal/overflow half of the tasks in the buffer to make room for future push()es.
                // Migrating half amortizes the cost of stealing while requiring future pops to still use the buffer.
                // Acquire barrier to ensure the linked list creation after the steal only happens after we succesfully steal.
                var migrate = size / 2;
                head = self.head.tryCompareAndSwap(
                    head,
                    head +% migrate,
                    .Acquire,
                    .Monotonic,
                ) orelse {
                    // Link the migrated Nodes together
                    const first = self.array[head % capacity].loadUnchecked();
                    while (migrate > 0) : (migrate -= 1) {
                        const prev = self.array[head % capacity].loadUnchecked();
                        head +%= 1;
                        prev.next = self.array[head % capacity].loadUnchecked();
                    }

                    // Append the list that was supposed to be pushed to the end of the migrated Nodes
                    const last = self.array[(head -% 1) % capacity].loadUnchecked();
                    last.next = list.head;
                    list.tail.next = null;

                    // Return the migrated nodes + the original list as overflowed
                    list.head = first; 
                    return error.Overflow;
                };
            }
        }

        fn pop(self: *Buffer) ?*Node {
            var head = self.head.load(.Monotonic);
            var tail = self.tail.loadUnchecked(); // we're the only thread that can change this

            while (true) {
                // Quick sanity check and return null when not empty
                var size = tail -% head;
                assert(size <= capacity);
                if (size == 0) {
                    return null;
                }

                // On x86, a fetchAdd ("lock xadd") can be faster than a tryCompareAndSwap ("lock cmpxchg").
                // If the increment makes the head go past the tail, it means the queue was emptied before we incremented so revert.
                // Acquire barrier to ensure that any writes we do to the popped Node only happen after the head increment.
                if (comptime std.builtin.target.cpu.arch.isX86()) {
                    head = self.head.fetchAdd(1, .Acquire);
                    if (head == tail) {
                        self.head.store(head, .Monotonic);
                        return null;
                    }

                    size = tail -% head;
                    assert(size <= capacity);
                    return self.array[head % capacity].loadUnchecked();
                }

                // Dequeue with an acquire barrier to ensure any writes done to the Node
                // only happen after we succesfully claim it from the array.
                head = self.head.tryCompareAndSwap(
                    head,
                    head +% 1,
                    .Acquire,
                    .Monotonic,
                ) orelse return self.array[head % capacity].loadUnchecked();
            }
        }

        const Stole = struct {
            node: *Node,
            pushed: bool,
        };

        fn canSteal(self: *const Buffer) bool {
            while (true) : (std.atomic.spinLoopHint()) {
                const head = self.head.load(.Acquire);
                const tail = self.tail.load(.Acquire);

                // On x86, the target buffer thread uses fetchAdd to increment the head which can go over if it's zero.
                // Account for that here by understanding that it's empty here.
                if (comptime std.builtin.target.cpu.arch.isX86()) {
                    if (head == tail +% 1) {
                        return false;
                    }
                }

                const size = tail -% head;
                if (size > capacity) {
                    continue;
                }

                assert(size <= capacity);
                return size != 0;
            }
        }

        fn consume(noalias self: *Buffer, noalias queue: *Queue) ?Stole {
            var consumer = queue.tryAcquireConsumer() catch return null;
            defer queue.releaseConsumer(consumer);

            const head = self.head.load(.Monotonic);
            const tail = self.tail.loadUnchecked(); // we're the only thread that can change this

            const size = tail -% head;
            assert(size <= capacity);
            assert(size == 0); // we should only be consuming if our array is empty

            // Pop nodes from the queue and push them to our array.
            // Atomic stores to the array as steal() threads may be atomically reading from it.
            var pushed: Index = 0;
            while (pushed < capacity) : (pushed += 1) {
                const node = queue.pop(&consumer) orelse break;
                self.array[(tail +% pushed) % capacity].store(node, .Unordered);
            }

            // We will be returning one node that we stole from the queue.
            // Get an extra, and if that's not possible, take one from our array.
            const node = queue.pop(&consumer) orelse blk: {
                if (pushed == 0) return null;
                pushed -= 1;
                break :blk self.array[(tail +% pushed) % capacity].loadUnchecked();
            };

            // Update the array tail with the nodes we pushed to it.
            // Release barrier to synchronize with Acquire barrier in steal()'s to see the written array Nodes.
            if (pushed > 0) self.tail.store(tail +% pushed, .Release);
            return Stole{
                .node = node,
                .pushed = pushed > 0,
            };
        }

        fn steal(noalias self: *Buffer, noalias buffer: *Buffer) ?Stole {
            const head = self.head.load(.Monotonic);
            const tail = self.tail.loadUnchecked(); // we're the only thread that can change this

            const size = tail -% head;
            assert(size <= capacity);
            assert(size == 0); // we should only be stealing if our array is empty

            while (true) : (std.atomic.spinLoopHint()) {
                const buffer_head = buffer.head.load(.Acquire);
                const buffer_tail = buffer.tail.load(.Acquire);

                // On x86, the target buffer thread uses fetchAdd to increment the head which can go over if it's zero.
                // Account for that here by understanding that it's empty here.
                if (comptime std.builtin.target.cpu.arch.isX86()) {
                    if (buffer_head == buffer_tail +% 1) {
                        return null;
                    }
                }

                // Overly large size indicates the the tail was updated a lot after the head was loaded.
                // Reload both and try again.
                const buffer_size = buffer_tail -% buffer_head;
                if (buffer_size > capacity) {
                    continue;
                }

                // Try to steal half (divCeil) to amortize the cost of stealing from other threads.
                const steal_size = buffer_size - (buffer_size / 2);
                if (steal_size == 0) {
                    return null;
                }

                // Copy the nodes we will steal from the target's array to our own.
                // Atomically load from the target buffer array as it may be pushing and atomically storing to it.
                // Atomic store to our array as other steal() threads may be atomically loading from it as above.
                var i: Index = 0;
                while (i < steal_size) : (i += 1) {
                    const node = buffer.array[(buffer_head +% i) % capacity].load(.Unordered);
                    self.array[(tail +% i) % capacity].store(node, .Unordered);
                }

                // Try to commit the steal from the target buffer using:
                // - an Acquire barrier to ensure that we only interact with the stolen Nodes after the steal was committed.
                // - a Release barrier to ensure that the Nodes are copied above prior to the committing of the steal
                //   because if they're copied after the steal, the could be getting rewritten by the target's push().
                _ = buffer.head.compareAndSwap(
                    buffer_head,
                    buffer_head +% steal_size,
                    .AcqRel,
                    .Monotonic,
                ) orelse {
                    // Pop one from the nodes we stole as we'll be returning it
                    const pushed = steal_size - 1;
                    const node = self.array[(tail +% pushed) % capacity].loadUnchecked();

                    // Update the array tail with the nodes we pushed to it.
                    // Release barrier to synchronize with Acquire barrier in steal()'s to see the written array Nodes.
                    if (pushed > 0) self.tail.store(tail +% pushed, .Release);
                    return Stole{
                        .node = node,
                        .pushed = pushed > 0,
                    };
                };
            }
        }
    };
};

/// An event which stores 1 semaphore token and is multi-threaded safe.
/// The event can be shutdown(), waking up all wait()ing threads and 
/// making subsequent wait()'s return immediately.
const Event = struct {
    state: Atomic(u32) = Atomic(u32).init(EMPTY),

    const EMPTY = 0;
    const WAITING = 1;
    const NOTIFIED = 2;
    const SHUTDOWN = 3;

    /// Wait for and consume a notification
    /// or wait for the event to be shutdown entirely
    noinline fn wait(self: *Event) void {
        var acquire_with: u32 = EMPTY;
        var state = self.state.load(.Monotonic);

        while (true) {
            // If we're shutdown then exit early.
            // Acquire barrier to ensure operations before the shutdown() are seen after the wait().
            // Shutdown is rare so it's better to have an Acquire barrier here instead of on CAS failure + load which are common.
            if (state == SHUTDOWN) {
                std.atomic.fence(.Acquire);
                return;
            }

            // Consume a notification when it pops up.
            // Acquire barrier to ensure operations before the notify() appear after the wait().
            if (state == NOTIFIED) {
                state = self.state.tryCompareAndSwap(
                    state,
                    acquire_with,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
                continue;
            }

            // There is no notification to consume, we should wait on the event by ensuring its WAITING.
            if (state != WAITING) blk: {
                state = self.state.tryCompareAndSwap(
                    state,
                    WAITING,
                    .Monotonic,
                    .Monotonic,
                ) orelse break :blk;
                continue;
            }

            // Wait on the event until a notify() or shutdown().
            // If we wake up to a notification, we must acquire it with WAITING instead of EMPTY
            // since there may be other threads sleeping on the Futex who haven't been woken up yet.
            //
            // Acquiring to WAITING will make the next notify() or shutdown() wake a sleeping futex thread
            // who will either exit on SHUTDOWN or acquire with WAITING again, ensuring all threads are awoken.
            // This unfortunately results in the last notify() or shutdown() doing an extra futex wake but that's fine. 
            std.Thread.Futex.wait(&self.state, WAITING, null) catch unreachable;
            state = self.state.load(.Monotonic);
            acquire_with = WAITING;
        }
    }

    /// Post a notification to the event if it doesn't have one already
    /// then wake up a waiting thread if there is one as well.
    fn notify(self: *Event) void {
        return self.wake(NOTIFIED, 1);
    }

    /// Marks the event as shutdown, making all future wait()'s return immediately.
    /// Then wakes up any threads currently waiting on the Event.
    fn shutdown(self: *Event) void {
        return self.wake(SHUTDOWN, std.math.maxInt(u32));
    }

    noinline fn wake(self: *Event, release_with: u32, wake_threads: u32) void {
        // Update the Event to notifty it with the new `release_with` state (either NOTIFIED or SHUTDOWN).
        // Release barrier to ensure any operations before this are this to happen before the wait() in the other threads.
        const state = self.state.swap(release_with, .Release);

        // Only wake threads sleeping in futex if the state is WAITING.
        // Avoids unnecessary wake ups.
        if (state == WAITING) {
            std.Thread.Futex.wake(&self.state, wake_threads);
        }
    }
};