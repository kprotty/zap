const std = @import("std");
const ThreadPool = @This();

const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

stack_size: u32,
max_threads: u32,
sync: Atomic(u32) = Atomic(u32).init(@bitCast(u32, Sync{})),
idle_event: Event = .{},
join_event: Event = .{},
run_queue: Node.Queue = .{},
threads: Atomic(?*Thread) = Atomic(?*Thread).init(null),

const Sync = packed struct {
    /// Tracks the number of threads not searching for Tasks
    idle: u14 = 0,
    /// Tracks the number of threads spawned
    spawned: u14 = 0,
    /// What you see is what you get
    unused: bool = false,
    /// Used to not miss notifications while state = waking
    notified: bool = false,
    /// The current state of the thread pool
    state: enum(u2) {
        /// A notification can be issued to wake up a sleeping as the "waking thread".
        pending = 0,
        /// The state was notifiied with a signal. A thread is woken up.
        /// The first thread to transition to `waking` becomes the "waking thread".
        signaled,
        /// There is a "waking thread" among us.
        /// No other thread should be woken up until the waking thread transitions the state.
        waking,
        /// The thread pool was terminated. Start decremented `spawned` so that it can be joined.
        shutdown,
    } = .pending,
};

/// Configuration options for the thread pool.
/// TODO: add CPU core affinity?
pub const Config = struct {
    stack_size: u32 = (std.Thread.SpawnConfig{}).stack_size,
    max_threads: u32,
};

/// Statically initialize the thread pool using the configuration.
pub fn init(config: Config) ThreadPool {
    return .{
        .stack_size = std.math.max(1, config.stack_size),
        .max_threads = std.math.max(1, config.max_threads),
    };
}

/// Wait for a thread to call shutdown() on the thread pool and kill the worker threads.
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

pub noinline fn schedule(noalias self: *ThreadPool, noalias task: *Task) error{Shutdown}!void {
    // Push the task to the most approriate queue
    if (Thread.current) |thread| {
        thread.push(task);
    } else {
        self.run_queue.push(Node.List{
            .head = &task.node,
            .tail = &task.node,
        });
    }
    
    // Fast path to check the Sync state to avoid calling into notify()
    const sync = @bitCast(Sync, self.sync.load(.Monotonic));
    if (sync.state == .shutdown) return error.Shutdown;
    if (sync.notified) return;
    
    // Try to notify a thread
    const is_waking = false;
    return self.notify(is_waking);
}

noinline fn notify(self: *ThreadPool, is_waking: bool) error{Shutdown}!void {
    var sync = @bitCast(Sync, self.sync.load(.Monotonic));
    while (true) {
        if (sync.state == .shutdown) return error.Shutdown;
        if (is_waking) assert(sync.state == .waking);

        const can_wake = is_waking or (sync.state == .pending);
        const max_threads = self.max_threads;

        var new_sync = sync;
        new_sync.notified = true;
        if (can_wake and sync.idle > 0) { // wake up an idle thread
            new_sync.state = .signaled;
        } else if (can_wake and sync.spawned < max_threads) { // spawn a new thread
            new_sync.state = .signaled;
            new_sync.spawned += 1;
        } else if (is_waking) { // no other thread to pass on "waking" status
            new_sync.state = .pending;
        } else if (sync.notified) { // nothing to update
            return;
        }
        
        sync = @bitCast(Sync, self.sync.tryCompareAndSwap(
            @bitCast(u32, sync),
            @bitCast(u32, new_sync),
            .AcqRel,
            .Monotonic,
        ) orelse {
            // We signaled to notify an idle thread
            if (can_wake and sync.idle > 0) {
                return self.idle_event.notify();
            }

            // We signaled to spawn a new thread
            if (can_wake and sync.spawned < max_threads) {
                // Call the function directly for single threaded cuz why not
                if (std.builtin.single_threaded) {
                    return Thread.run(self);
                }

                const spawn_config = std.Thread.SpawnConfig{ .stack_size = self.stack_size };
                const thread = std.Thread.spawn(spawn_config, Thread.run, .{self}) catch return self.unregister(null);
                return thread.detach();
            }

            return;
        });
    }
}

noinline fn wait(self: *ThreadPool, _is_waking: bool) error{Shutdown}!bool {
    var is_idle = false;
    var is_waking = _is_waking;
    var sync = @bitCast(Sync, self.sync.load(.Monotonic));

    while (true) {
        if (sync.state == .shutdown) return error.Shutdown;
        if (is_waking) assert(sync.state == .waking);

        if (sync.notified or !is_idle) {
            var new_sync = sync;
            new_sync.notified = false;

            if (sync.state == .signaled)
                new_sync.state = .waking;
            if (sync.notified and is_idle)
                new_sync.idle -= 1;
            if (!sync.notified and !is_idle)
                new_sync.idle += 1;
            if (!sync.notified and is_waking)
                new_sync.state = .pending;

            if (self.sync.tryCompareAndSwap(
                @bitCast(u32, sync),
                @bitCast(u32, new_sync),
                .AcqRel,
                .Monotonic,
            )) |updated| {
                sync = @bitCast(Sync, updated);
                continue;
            }

            if (sync.notified) {
                return is_waking or (sync.state == .signaled);
            }
        }

        is_idle = true;
        is_waking = false;
        self.idle_event.wait();
        sync = @bitCast(Sync, self.sync.load(.Monotonic));
    }
}

pub noinline fn shutdown(self: *ThreadPool) void {
    var sync = @bitCast(Sync, self.sync.load(.Monotonic));
    while (sync.state != .shutdown) {
        var new_sync = sync;
        new_sync.notified = true;
        new_sync.state = .shutdown;
        new_sync.idle = 0;

        sync = @bitCast(Sync, self.sync.tryCompareAndSwap(
            @bitCast(u32, sync),
            @bitCast(u32, new_sync),
            .AcqRel,
            .Monotonic,
        ) orelse {
            if (sync.idle > 0) self.idle_event.shutdown();
            return;
        });
    }
}

fn register(noalias self: *ThreadPool, noalias thread: *Thread) void {
    // Push the thread onto the threads stack in a lock-free manner.
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

fn unregister(noalias self: *ThreadPool, noalias maybe_thread: ?*Thread) error{Shutdown}!void {
    // Un-spawn one thread, either due to a failed OS thread spawning or the thread is exitting.
    const one_spawned = @bitCast(u32, Sync{ .spawned = 1 });
    const sync = @bitCast(Sync, self.sync.fetchSub(one_spawned, .Release));
    assert(sync.spawned > 0);

    // The last thread to exit must wake up the thread pool join()er
    // who will start the chain to shutdown all the threads.
    if (sync.state == .shutdown and sync.spawned == 1) {
        self.join_event.notify();
    }

    // If this is a thread pool thread, wait for a shutdown signal by the thread pool join()er.
    // After receiving the shutdown signal, shutdown the next thread in the pool.
    // We have to do that without touching the thread pool itself since it's memory is invalidated by now.
    // So just follow our .next link.
    if (maybe_thread) |thread| blk: {
        thread.join_event.wait();
        const next = thread.next orelse break :blk;
        next.join_event.notify();
    }
    
    // Report shutdown for when this is called via notify().
    if (sync.state == .shutdown) {
        return error.Shutdown;
    }
}

fn join(self: *ThreadPool) void {
    // Wait for the thread pool to be shutdown() then for all threads to enter a joinable state
    var sync = @bitCast(Sync, self.sync.load(.Monotonic));
    if (!(sync.state == .shutdown and sync.spawned == 0)) {
        self.join_event.wait();
        sync = @bitCast(Sync, self.sync.load(.Monotonic));
    }

    assert(sync.state == .shutdown);
    assert(sync.spawned == 0);

    // If there are threads, start off the chain sending it the shutdown signal.
    // The thread receives the shutdown signal and sends it to the next thread, and the next..
    const thread = self.threads.load(.Acquire) orelse return;
    thread.join_event.notify();
}

const Thread = struct {
    next: ?*Thread = null,
    target: ?*Thread = null,
    join_event: Event = .{},
    run_queue: Node.Queue = .{},
    run_buffer: Node.Buffer = .{},
    
    threadlocal var current: ?*Thread = null;

    /// Thread entry point which runs a worker for the ThreadPool
    fn run(thread_pool: *ThreadPool) void {
        var self = Thread{};
        current = &self;

        thread_pool.register(&self);
        defer thread_pool.unregister(&self) catch {};

        var is_waking = false;
        while (true) {
            is_waking = thread_pool.wait(is_waking) catch break;

            while (self.pop(thread_pool)) |result| {
                if (result.pushed or is_waking) 
                    thread_pool.notify(is_waking) catch break;
                is_waking = false;

                const task = @fieldParentPtr(Task, "node", result.node);
                (task.callback)(task);
            }
        }
    }

    /// Pushses a Task/Node into the ThreadPool that the Thread is apart of.
    fn push(noalias self: *Thread, noalias task: *Task) void {
        var overflowed: Node.List = undefined;
        self.run_buffer.push(&task.node, &overflowed) catch {
            self.run_queue.push(overflowed);
        };
    }

    /// Try to dequeue a Node/Task from the ThreadPool.
    /// Spurious reports of dequeue() returning empty are allowed.
    fn pop(noalias self: *Thread, noalias thread_pool: *ThreadPool) ?Node.Buffer.Stole {
        // Check our local buffer first
        if (self.run_buffer.pop()) |node| {
            return Node.Buffer.Stole{
                .node = node,
                .pushed = false,
            };
        }

        return self.popSlow(thread_pool);
    }

    noinline fn popSlow(noalias self: *Thread, noalias thread_pool: *ThreadPool) ?Node.Buffer.Stole {
        // Then check our local queue
        if (self.run_buffer.consume(&self.run_queue)) |stole| {
            return stole;
        }

        // Then the global queue
        if (self.run_buffer.consume(&thread_pool.run_queue)) |stole| {
            return stole;
        }
        
        // Then try work stealing from other threads
        var num_threads: u32 = @bitCast(Sync, thread_pool.sync.load(.Monotonic)).spawned;
        while (num_threads > 0) : (num_threads -= 1) {
            // Traverse the stack of registered threads on the thread pool
            const target = self.target orelse thread_pool.threads.load(.Acquire) orelse unreachable;
            self.target = target.next;

            // Try to steal from their queue first to avoid contention (the target steal's from queue last).
            if (self.run_buffer.consume(&target.run_queue)) |stole| {
                return stole;
            }

            // Skip stealing from the buffer if we're the target.
            // We still steal from our own queue above given it may have just been locked the first time we tried.
            if (target == self) {
                continue;
            }

            // Steal from the buffer of a remote thread as a last resort
            if (self.run_buffer.steal(&target.run_buffer)) |stole| {
                return stole;
            }
        }

        return null;
    }
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

        fn push(noalias self: *Queue, list: List) void {
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

        fn push(
            noalias self: *Buffer,
            noalias node: *Node,
            noalias overflow_ref: *List,
        ) error{Overflow}!void {
            var head = self.head.load(.Monotonic);
            const tail = self.tail.loadUnchecked(); // we're the only thread that can change this
            
            while (true) {
                const size = tail -% head;
                assert(size <= capacity);
                
                // Push to the buffer if it's not empty.
                // Release barrier synchronizes with Acquire loads for steal()ers to see the array writes.
                // Array written atomically with weakest ordering since it could be getting atomically read by steal().
                if (size < capacity) {
                    self.array[tail % capacity].store(node, .Unordered);
                    self.tail.store(tail +% 1, .Release);
                    return;
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

                    // Attach the node that was supposed to be pushed to the end of the linked list
                    const last = self.array[(head -% 1) % capacity].loadUnchecked();
                    last.next = node;
                    node.next = null;

                    // Mark the migrated task as overflowed for the caller
                    overflow_ref.* = .{ .head = first, .tail = node };
                    return error.Overflow;
                };
            }
        }

        fn pop(self: *Buffer) ?*Node {
            var head = self.head.load(.Monotonic);
            var tail = self.tail.loadUnchecked(); // we're the only thread that can change this

            while (true) {
                const size = tail -% head;
                assert(size <= capacity);
                if (size == 0) {
                    return null;
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