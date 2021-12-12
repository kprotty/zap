const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

co_prime: usize,
buffers: []Buffer,
injector: Injector = .{},
idle_sema: Semaphore = .{},
join_sema: Semaphore = .{},
state: Atomic(usize) = Atomic(usize).init(@bitCast(usize, State{})),

/// A worker represents a thread in the thread pool.
/// The user provides a contiguous array of workers for each OS thread.
/// The contents of the Worker is meant to be opaque towards the user.
pub const Worker = Buffer;

/// Initialize ithe thread pool with the workers provided.
pub fn init(workers: []Worker) ThreadPool {
    // Workers are really "threadlocal Runnable buffers" so convert it into that for internal use.
    // Limit the amount of workers to that which we can atomically represent in the state.
    const num_buffers = std.math.min(workers.len, std.math.maxInt(State.Count));
    const buffers = workers.ptr[0..num_buffers];
    assert(buffers.len > 0);

    // Compute the coprime of the worker counter in order to iterate over it randomly.
    // The coprime is any number from 0..n (p) where gcd(p, n) == 1
    var n = buffers.len / 2;
    const co_prime = while (n <= buffers.len) : (n += 1) {
        var gcd = n;
        var range = buffers.len;
        while (gcd != range) {
            if (gcd > range) {
                gcd -= range;
            } else {
                range -= gcd;
            }
        }
        if (gcd == 1) 
            break n;
    } else unreachable;

    return .{
        .co_prime = co_prime,
        .buffers = buffers,
    };
}

/// Shuts down the thread-pool, waiting for all workers to complete.
/// Once deinitialized, the thread pool must not be used again unless reinitialized.
pub fn deinit(self: *ThreadPool) void {
    self.join(); 
    self.* = undefined;
}

/// A Runnable is a job/task/unit-of-work in regards to the thread pool.
/// Runnables must have their `runFn` user initialized which is called when the runnable is executed.
/// Once runnables are scheduled, they must remain valid until their runFn is invoked.
/// Context for the Runnable is normally derived by storing the Runnable in a struct and using @fieldParentPtr().
pub const Runnable = extern struct {
    next: ?*Runnable = null,
    runFn: fn (*Runnable) void,
};

/// A Batch is an unordered set of Runnables that can be scheduled as a group.
/// Whether the Batch stores Runnables in FIFO or LIFO order is unspecified,
/// however all fields of the Batch are public and allowed to be inspected but not modified.
pub const Batch = extern struct {
    len: usize = 0,
    head: ?*Runnable = null,
    tail: ?*Runnable = null,

    /// Create a Batch from a single Runnable.
    pub fn from(runnable: *Runnable) Batch {
        runnable.next = null;
        return .{
            .len = 1,
            .head = runnable,
            .tail = runnable,
        };
    }

    /// Push the given Batch to our Batch.
    /// This effectively consumes the pushed Batch meaning that it must no longer be used.
    pub fn push(self: *Batch, batch: Batch) void {
        const prev_ptr = if (self.tail) |tail| &tail.next else &self.head;
        prev_ptr.* = batch.head orelse return;
        self.tail = batch.tail orelse unreachable;
        self.len += batch.len;
    }

    /// Dequeue a Runnable from our Batch.
    /// Runnables can be interated/peeked by observing the batch head/tail.
    pub fn pop(self: *Batch) ?*Runnable {
        const runnable = self.head orelse return null;
        self.head = runnable.next;
        if (self.head == null) self.tail = null;
        self.len -= 1;
        return runnable;
    }
};

/// Schedule a Batch of Runnables for execution on the thread pool.
/// This effectively consumes the pushed Batch meaning that it must no longer be used.
/// Runnables in the Batch scheduled to the thread pool as expected to remain valid until executed.
pub fn schedule(self: *ThreadPool, batch: Batch) void {
    var mut_batch = batch;
    if (mut_batch.len == 0)
        return;
    
    // Try to push one of the batch's runnables to the local Runnable Buffer
    // if this thread is actually a thread pool worker thread.
    if (Buffer.current) |buffer| {
        if (blk: {
            const buffer_ptr = @ptrToInt(buffer);
            const buffers_begin = @ptrToInt(self.buffers.ptr);
            const buffers_end = buffers_begin + (self.buffers.len * @sizeOf(Buffer));
            break :blk (buffer_ptr >= bufers_begin) and (buffer_ptr < buffers_end);
        }) {
            const runnable = mut_batch.pop() orelse unreachable;
            buffer.push(runnable, &self.injector);
        }
    }
    
    // Push any remaining Runnables from the batch to the shared injector
    // then notify the worker threads that Runnables have been pushed.
    self.injector.push(mut_batch);
    self.notify();

    // NOTE: injector.push() is AcqRel which contains an Acquire fence.
    // This Acquire fence is important to avoid the following race condition interleaving:
    //
    // - last_active_worker: sees empty buffers and injector
    // - schedule(): **load() in notify() reordered before injector.push()**
    // - last_active_worker: state.idle -= 1 and state.searching -= 1 since saw empty
    // - last_active_worker: checks injector again, still empty, goes to sleep
    // - schedule(): injector.push()
    // - schedule(): notify() but load above showed searching > 0 or idle == 0 so returns
    // - **workers as still asleep while there's runnables in the injector!**
    //
    // This is only important when schedule() is called from a non-worker thread (one without Buffer.current)
    // as at least the worker thread will eventually see the runnable scheduled on its own.
}

/// The state is an atomically accessed & updated group of counters for the thread pool
const State = packed struct {
    /// Keeps track of the number of worker threads who've have or will wait on idle_sema.
    idle: Count = 0,
    /// Keeps track of the active worker threads in order to limit thread spawning & wait for them to exit.
    spawned: Count = 0,
    /// Keeps track of the worker threads work-stealing / looking for work outside their local Buffer
    searching: Count = 0,
    /// Value which becomes non-zero when the thread pool has been shutdown as is waiting for worker threads to exit.
    terminated: Padding = 0,

    const Count = std.meta.Int(.unsigned, @bitSizeOf(usize) / 3);
    const Padding = std.meta.Int(.unsigned, @bitSizeOf(usize) % 3);
};

/// Creates or wakes up worker threads to process Runnables if they aren't already.
fn notify(self: *ThreadPool) void {
    var state = @bitCast(State, self.state.load(.Monotonic));
    while (true) {
        // Don't do anything if the thread pool is shutting down
        var new_state = state;
        if (state.terminated != 0)
            return;

        // Don't wake/spawn if there's already threads searching for work.
        // This is the primary throttling mechanism to avoid contention & extra syscalls.
        new_state.searching = 1;
        if (state.searching > 0)
            return;

        // Either wake up an idle worker or spawn a new one.
        // We won't be able to iff:
        // - all possible worker threads have been spawned
        // - none are idle they're all busy with *something*
        // - none are searching as per ruled out above
        // 
        // This either means that all worker threads are busy executing Runnables
        // since they're not looking for work, or they're above to start searching/go idle.
        // In that case, leave them be to find the new work that be scheduled()'d above.
        if (state.idle > 0) {
            new_state.idle -= 1;
        } else if (state.spawned < self.buffers.len) {
            new_state.spawned += 1;
        } else {
            return;
        }

        // Release barrier to ensure that schedule() stays before the state change.
        state = @bitCast(State, self.state.tryCompareAndSwap(
            @bitCast(usize, state),
            @bitCast(usize, new_state),
            .Release,
            .Monotonic,
        ) orelse {
            // Wake up an idle worker thread if any.
            if (state.idle > 0)
                return self.idle_sema.post(1);

            // Spawn a new worker thread.
            assert(state.spawned < self.buffers.len);
            const buffer_index = state.spawned;

            const thread = std.Thread.spawn(.{}, run, .{self, buffer_index}) catch {
                // If we fail, we need to call complete(searching=true) to 
                // undo the state change we did (which was to bump searching and bump spawned).
                self.complete(true);
                return;
            };

            thread.detach();
            return;
        });
    }
}

/// Updates the state to indicate that a worker thread was "despawned".
fn complete(self: *ThreadPool, was_searching: bool) void {
    const one_searching = @bitCast(usize, State{ .searching = 1 });
    const search_shift = @ctz(usize, one_searching);

    /// Also bumps down the searching count if `was_searching` is true.
    var update = @bitCast(usize, State{ .spawned = 1 });
    update +%= @as(usize, @boolToInt(was_searching)) << search_shift;

    // Release to ensure all worker operations on the thread pool happen before we despawn.
    // Acquire to synchronize with all worker thread Release's at this same spot so that if we're the last, 
    // all worker threads at that point must have stopped accessing the thread pool.
    // Acquire barrier also ensure that the join_sema.post() below only happens after we despawn.
    const state = @bitCast(State, self.state.fetchSub(update, .AcqRel));
    assert(state.searching <= self.buffers.len);
    assert(state.searching >= @boolToInt(was_searching));

    // The last worker thread to despawn while knowing that the thread pool is shutting down 
    // must notify the join() thread that all worker threads have now been shut down.
    assert(state.spawned <= self.buffers.len);
    assert(state.spawned > 0);
    if (state.spawned == 1 and state.terminated != 0)
        self.join_sema.post(1);
}

/// Starts the shut down of the thread pool and waits for all worker threads to complete().
fn join(self: *ThreadPool) void {
    var state = @bitCast(State, self.state.load(.Monotonic));
    while (true) {
        // There should only be one thread calling join() and starting shutdown at any point. 
        assert(state.terminated == 0);

        // Mark the thread pool state as terminated (shutting down).
        // Also wake up all idle worker threads while marking them as searching since they assume that on wake up.
        var new_state = state;
        new_state.idle = 0;
        new_state.terminated = 1;
        new_state.searching += state.idle;

        // Release to ensure all operations on the thread pool prior happen before the shut down process begins.
        // Acquire to ensure that the join_sema.wait() loads happen after the shut down process begins.
        state = @bitCast(State, self.state.tryCompareAndSwap(
            @bitCast(usize, state),
            @bitCast(usize, new_state),
            .AcqRel,
            .Monotonic,
        ) orelse {
            // Wake up all idle worker threads
            if (state.idle > 0)
                self.idle_sema.post(@intCast(u31, state.idle));
            
            // Wait for worker threads to despawn/complete()
            if (state.spawned > 0)
                self.join_sema.wait();

            // Quick sanity check to ensure everything's done.
            // Unordered at least to avoid unsoundness in case there's still other threads.
            state = @bitCast(State, self.state.load(.Unordered));
            assert(state.idle == 0);
            assert(state.spawned == 0);
            assert(state.searching == 0);
            return;
        });
    }
}

/// Tries to mark the caller worker thread as "searching".
/// There's a quick soft-limit here to limit searching workers which decreases atomic contention overhead.
/// Multiplication of searching is used instead of division of buffers as mul is often faster than div on modern CPUs.
/// Each observation of the state, we do a sanity check to ensure "searching" doesn't overflow the amount of buffers.
fn markSearching(self: *ThreadPool) bool {
    var state = @bitCast(State, self.state.load(.Monotonic));
    assert(state.searching <= self.buffers.len);
    if ((2 * state.searching) >= self.buffers.len)
        return false;

    // Acquire barrier to ensure search() only happens after we've bumped the searching count.
    const update = @bitCast(usize, State{ .searching = 1 });
    state = @bitCast(State, self.state.fetchAdd(update, .Acquire));
    assert(state.searching < self.buffers.len);
    return true;
}

/// Once a searching worker threads finds a Runnable to execute, it calls this function.
/// The last searching thread to find a Runnable must try to wake up another worker thread.
/// This implements wake up throttling which both decreases searching contention and average syscall latency of notify().
fn markDiscovered(self: *ThreadPool) void {
    // Release barrier to ensure the search() previously don't happens before we bump down searching for the next worker thread.
    const update = @bitCast(usize, State{ .searching = 1 });
    const state = @bitCast(State, self.state.fetchSub(update, .Release));
    
    // The load() in notify() cant be reordered before the fetchSub() since they're on the same atomic variable
    assert(state.searching <= self.buffers.len);
    assert(state.searching > 0);
    if (state.searching == 1)
        self.notify();
}

/// Before putting a worker thread to sleep, this must be called to ensure it can be woken up after.
/// This bumps up the idle count and bumps down the searching count if the worker therad was searching before going idle.
/// The last searching thread to go idle must check the injector again and issue a notify() to avoid a race described below.
fn markIdle(self: *ThreadPool, was_searching: bool) error{Shutdown}!void {
    const one_searching = @bitCast(usize, State{ .searching = 1 });
    const search_shift = @ctz(usize, one_searching);

    var update = @bitCast(usize, State{ .idle = 1 });
    update -%= @as(usize, @boolToInt(was_searching)) << search_shift;

    // Acquire to ensure that the injector.pending() check is done after the searching is decremented.
    // Release to ensure that search() happens before the searching is decremented or our marking of idle.
    var state = @bitCast(State, self.state.fetchAdd(update, .AcqRel));
    assert(state.idle < self.buffers.len);
    assert(state.searching <= self.buffers.len);
    assert(state.searching >= @boolToInt(was_searching));

    // If the thread pool is shutting down, we need to undo the idle inc we did above.
    // Once shutting down, it is expected that there will no longer be any threads sleeping on idle_sema.
    if (state.terminated != 0) {
        state = @bitCast(State, self.state.fetchSub(update, .Monotonic));
        assert(state.idle <= self.buffers.len);
        assert(state.idle > 0);
        return error.Shutdown;
    }

    // We were the last searching worker thread. 
    // Send a notification if we detect work as pushed while we were decrementing searching.
    // This helps avoid this race condition:
    //
    // - last_worker: search failed, calls markIdle(), is preempted
    // - schedule(): pushes to injector, notify() sees state.searching > 1 and returns
    // - last_worker: state.searching -= 1 -> state.searching=0 which would now be notify()'able
    // - last_worker: **if doesn't check injector again, goes to sleep while theres runnables in injector**
    //
    // Note that the injector check must strictly happen after the searching count is decremented to avoid the race.
    // Only the injector is checked instead of all buffers as this race only produces deadlock for work outside the thread pool.
    // A running worker prevents this by ensuring that it will eventually poll for tasks later.
    if (was_searching and state.searching == 1 and self.injector.pending())
        self.notify();
}

/// Entry point and executor loop for a worker thread
fn run(self: *ThreadPool, buffer_index: usize) void {
    // A worker starts off as searching as per the state update done in notify().
    // Once finished, it's "despawned" from the thread pool, making sure not to access it after as it can be invalidated.
    var is_searching = true;
    defer self.complete(is_searching);

    // Set the thread local buffer for the worker
    const buffer = &self.buffers[buffer_index];
    Buffer.current = buffer;

    // Seed the Xorshift PRNG (0 value is invalid)
    var xorshift = buffer_index;
    if (xorshift == 0)
        xorshift = 0xdeadbeef;

    while (true) {
        // Poll for a Runnable on the thread pool
        const polled = buffer.pop() orelse blk: {
            is_searching = is_searching or self.markSearching();
            if (is_searching) break :blk self.search(buffer, &xorshift);
            break :blk null;
        };

        // Stop searching for Runnables if we were
        const was_searching = is_searching;
        is_searching = false;

        // Execute the Runnables when found
        if (polled) |runnable| {
            if (was_searching) self.markDiscovered();
            (runnable.runFn)(runnable);
            continue;
        }

        // Wait on the thread pool and try again if we couldn't find any work.
        self.markIdle(was_searching) catch break;
        self.idle_sema.wait();
        is_searching = true;
    }
}

/// Using the provided buffer and the prng, 
/// perform work stealing on both the injector queue and other worker buffers.
fn search(self: *ThreadPool, buffer: *Buffer, xorshift: *usize) ?*Runnable {
    // number of steal iterations to attempt even when we've observed all Empty
    var retries: u8 = 1;
    // total number of steal iterations to possibly attempt before giving up (either to contention or empty)
    var attempts: u8 = 32;

    while (true) {
        // Try to steal work from the shared injector before checking other buffers 
        return buffer.inject(&self.injector) catch |inject_err| {
            const shifts = switch (@bitSizeOf(usize)) {
                64 => .{ 13, 17, 5 },
                32 => .{ 13, 7, 17 },
                else => @compileError("unsupported architecture"),
            };

            var rng = xorshift.*;
            rng ^= rng << shifts[0];
            rng ^= rng >> shifts[1];
            rng ^= rng << shifts[2];
            xorshift.* = rng;
            
            var iter = self.buffers.len;
            var steal_index = rng % self.buffers.len;
            var was_contended = inject_err == error.Contended;

            // Iterate and try to steal from all the buffers
            while (iter > 0) : (iter -= 1) {
                // Branchless version of algorithm which iterates all values from 0..self.buffers.len 
                // in a random order using the co_prime computed at init().
                // https://lemire.me/blog/2017/09/18/visiting-all-values-in-an-array-exactly-once-in-random-order/
                defer {
                    steal_index += self.co_prime;
                    steal_index -= self.buffers.len * @boolToInt(steal_index >= self.buffers.len);
                }

                // Don't steal from ourselves since we know our buffer is empty from failing pop()
                const steal_buffer = &self.buffers[steal_index];
                if (buffer == steal_buffer)
                    continue;

                return steal_buffer.steal() catch |steal_err| {
                    was_contended = was_contended or steal_err == error.Contended;
                    continue;
                };
            }

            // Bounded spinning on contention reduces the latency of stealing by
            // not transitioning to idle and going to sleep immediately
            // but also by not hogging the CPU indefinitely until the time quota expires.
            //
            // spinLoopHint() acts as a small delay to decrease contention and 
            // indicate to the cpu & compiler optimizer that we're intentionally looping
            // while waiting on an external condition.
            attempts = std.math.sub(u8, attempts, 1) catch return null;
            if (was_contended) {
                std.atomic.spinLoopHint();
                continue;
            }

            // Try to yield the time quota to another therad when we retry on Empty.
            // TODO: Should this be removed since it's technically unspecified?
            retries = std.math.sub(u8, retries, 1) catch return null;
            std.os.sched_yield() catch {};
        };
    }
}

/// An unbounded, MPMC queue of Runnables.
/// It's actually an MPSC where the consumer side is protected by a non-blocking "try-lock".
const Injector = extern struct {
    pushed: Atomic(?*Runnable) = Atomic(?*Runnable).init(null),
    popped: Atomic(?*Runnable) = Atomic(?*Runnable).init(null),

    fn push(self: *Injector, batch: Batch) void {
        if (batch.len == 0) return;
        const head = batch.head orelse unreachable;
        const tail = batch.tail orelse unreachable;

        // Pushes to the trieber stack using AcqRel instead of just Release:
        // - Release to ensure that consume()/Consumer.pop() sees the Runnable .next links on Acquire
        // - Acquire to ensure that notify() load after Injector.push() is not reordered before it (see schedule() comment)
        var pushed = self.pushed.load(.Monotonic);
        while (true) {
            tail.next = pushed;
            pushed = self.pushed.tryCompareAndSwap(
                pushed,
                head,
                .AcqlRel,
                .Monotonic.
            ) orelse break;
        }
    }

    /// The address of this valid is used to indicate that
    /// the consumer side (popped) is currently owned/held by a thread.
    var consuming: Runnable = undefined;

    /// Returns true if a thread could potentially consume Runnables from this Injector.
    fn pending(self: *const Injector) bool {
        const popped = self.popped.load(.Acquire);
        const pushed = self.pushed.load(.Acquire);

        const is_contended = popped == @as(?*Runnable, &consuming);
        const is_empty = popped == null and pushed == null;
        
        return !(is_empty or is_contended);
    }

    /// Tries to acquire a Consumer for the Injector
    /// which provides exclusive access to the consuming side to deque Runnables from it.
    fn consume(self: *Injector) error{Empty, Contended}!Consumer {
        var popped = self.popped.load(.Monotonic);
        while (true) {
            if (popped == null and self.pushed.load(.Monotonic) == null)
                return error.Empty;
            if (popped == @as(?*Runnable, &consuming))
                return error.Contended;
            
            // Acquire to ensure that we see the .next links observed by
            // the Acquire of pushed in Consumer.pop() then Release of popped in Consumer.release().
            // Acquire also ensures that we only start dequeing Runnables once we own the consumer side.
            popped = self.popped.tryCompareAndSwap(
                popped,
                &consuming,
                .Acquire,
                .Monotonic,
            ) orelse return Consumer{
                .injector = self,
                .popped = popped,
            };
        }
    }

    const Consumer = struct {
        injector: *Injector,
        popped: ?*Runnable,

        fn pop(self: *Consumer) ?*Runnable {
            const runnable = self.popped orelse self.injector.pushed.swap(null, .Acquire) orelse return null;
            self.popped = runnable.next;
            return runnable;
        }

        fn release(self: Consumer) void {
            assert(self.popped != @as(?*Runnable, &consuming));
            self.injector.popped.store(self.popped, .Release);
        }
    };
};

const Buffer = extern struct {
    threadlocal var current: ?*Buffer = null;

    head: Atomic(usize) = Atomic(usize).init(0),
    tail: Atomic(usize) = Atomic(usize).init(0),
    array: [capacity]@TypeOf(slot) = [_]@TypeOf(slot){slot} ** capacity,

    const capacity = 256;
    const slot = Array(?*Runnable).init(null);

    fn read(self: *Buffer, index: usize) *Runnable {
        const runnable_ptr = &self.array[index % self.array.len()];
        return runnable_ptr.load(.Unordered) orelse unreachable;
    }

    fn write(self: *Buffer, index: usize, runnable: *Runnable) void {
        runnable.next = self.array[index % self.array.len()].loadUnchecked();
        self.array[index % self.array.len()].store(runnable, .Unordered);
    }

    fn push(self: *Buffer, runnable: *Runnable, injector: *Injector) void {
        var head = self.head.load(.Monotonic);
        var tail = self.tail.loadUnchecked();

        while (true) {
            const size = tail -% head;
            assert(size <= capacity);

            if (size < capacity) {
                self.write(tail, runnable);
                self.tail.store(tail +% 1, .Release);
                return;
            }

            const migrate = size / 2;
            assert(migrate > 0);

            head = self.head.tryCompareAndSwap(
                head,
                head +% migrate,
                .Acquire,
                .Monotonic,
            ) orelse {
                var migrated = Batch{
                    .len = migrate,
                    .head = self.read(head +% (migrate - 1)),
                    .tail = self.read(head),
                };

                migrated.tail.next = null;
                migrated.push(Batch.from(runnable));
                self.injector.push(migrated);
                return;
            };
        }
    }

    fn pop(self: *Buffer) ?*Runnable {
        const tail = self.tail.loadUnchecked();
        const new_tail = tail -% 1;

        self.tail.store(new_tail, .SeqCst);
        const head = self.head.load(.SeqCst);

        const size = tail -% head;
        assert(size <= capacity);

        const runnable = self.read(new_tail);
        if (size > 1)
            return runnable;

        self.tail.store(tail, .Monotonic);
        if (size == 1) {
            _ = self.head.compareAndSwap(
                head,
                tail,
                .Acquire,
                .Monotonic,
            ) orelse return runnable;
        }

        return null;
    } 

    fn steal(self: *Buffer) error{Empty, Contended}!*Runnable {
        const head = self.head.load(.Acquire);
        const tail = self.tail.load(.Acquire);

        var size = tail -% head;
        if (tail == head -% 1)
            size = 0;

        assert(size <= capacity);
        if (size == 0)
            return error.Empty;

        const runnable = self.read(head);
        _ = self.head.compareAndSwap(
            head,
            head +% 1,
            .AcqRel,
            .Monotonic,
        ) orelse return runnable;
        return error.Contended;
    }

    fn inject(self: *Buffer, injector: *Injector) error{Empty, Contended}!*Runnable {
        var consumer = try injector.consume();
        defer consumer.release();
        const injected = consumer.pop() orelse return error.Empty;

        const head = self.head.load(.Monotonic);
        const tail = self.tail.loadUnchecked();

        const size = tail -% head;
        assert(size <= capacity);

        var new_tail = tail;
        defer if (tail != new_tail)
            self.tail.store(new_tail, .Release);

        var available = capacity - size;
        while (available > 0) : (available -= 1) {
            const runnable = consumer.pop() orelse break;
            self.write(new_tail, runnable);
            new_tail +%= 1;
        }

        return injected;        
    }
};

const Semaphore = struct {
    value: Atomic(i32) = Atomic(i32).init(0),
    counter: Atomic(u32) = Atomic(i32).init(0),

    fn wait(self: *Semaphore) void {
        const value = self.value.fetchSub(1, .Acquire);
        if (value > 0)
            return;

        while (true) {
            var counter = self.counter.load(.Monotonic);
            while (std.math.sub(u32, counter, 1) catch null) |new_counter| {
                counter = self.counter.tryCompareAndSwap(
                    counter,
                    new_counter,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
            }
            std.Thread.Futex.wait(&self.counter, 0, null) catch unreachable;
        }
    }

    fn post(self: *Semaphore, count: u31) void {
        const value = self.value.fetchAdd(count, .Release);
        if (value >= 0)
            return;

        const waiters = std.math.min(@intCast(u32, -value), count);
        _ = self.counter.fetchAdd(waiters, .Release);
        std.Thread.Futex.wake(&self.counter, count);
    }
};
