const zap = @import("../../zap.zig");
const meta = zap.meta;
const builtin = zap.builtin;
const atomic = zap.sync.atomic;

pub const Lock = extern struct {
    /// This is an unfair mutex lock implementation inspired by:
    ///  - parking_lot's WordLock: https://github.com/Amanieu/parking_lot/blob/master/core/src/word_lock.rs
    ///  - locklessinc's KeyedLock: http://www.locklessinc.com/articles/keyed_events/
    ///
    /// [  remaining: uX   | is_waking: u1 |  ignored: u7  | is_locked: u1 ]: usize
    ///
    /// - is_locked:
    ///     When set, indicates that the lock is currently owned.
    ///     Because it is only one bit, this allows an x86 optimization to use `lock bts` for acquire.
    ///
    /// - ignored:
    ///     These bits are ignored and used to effectively pad the `is_locked` bit to 8-bits/1-byte.
    ///     Having the `is_locked` bit in its own byte is a two-fold optimization:
    ///
    ///         Acquiring the lock for non x86 platforms can swap the entire u8 instead of a CAS on the whole usize.
    ///         This means that it does not have to compete with other waiters trying to CAS the whole usize.
    ///
    ///         Releasing the lock for all platforms is an atomic u8 store to the is_locked byte.
    ///         This means that unlocking on most platforms should require almost no (retry) synchronization.
    ///
    /// - is_waking:
    ///     When set, indicates that there is a waiter being woken up.
    ///     One release() thread will set this bit when trying to perform a wake up (while others can keep acquiring).
    ///     Once the waiter is woken up by the release() thread, the waiter will unset the is_waking bit themselves.
    ///     These have the effect of throttling wake-up in favor of throughput with the idea that a wake-up is expensive.
    ///
    /// - remaining:
    ///     The remaining of the usize bits represent the head Waiter pointer for the wait queue.
    ///     The queue is dequeued for Waiters in a FIFO ordering to avoid having to update the head (hence state) when contended.
    ///     The Waiter must then be aligned higher than the `is_waking` bit above in order for its lower bits to be used to encode the other states.
    ///
    state: usize = UNLOCKED,

    const UNLOCKED = 0;
    const LOCKED = 1 << 0;
    const WAKING = 1 << 8; // aligned past u8
    const WAITING = ~@as(usize, (1 << 9) - 1); // aligned past WAKING

    const Waiter = struct {
        prev: ?*Waiter align(meta.max(@alignOf(usize), ~WAITING + 1)),
        next: ?*Waiter,
        tail: ?*Waiter,
        wakeFn: fn(*Waiter) void,
    };

    /// Try to acquire the lock if its unlocked.
    pub fn tryAcquire(self: *Lock) bool {
        switch (builtin.arch) {
            // On x86, its better to use `lock bts` over `lock xchg`
            // as the former requires less instructions (lock-bts, jz)
            // over the latter (mov-reg-1, xchg, test, jz).
            //
            // For the fast path when there's no contention,
            // This helps in decreasing the hit on the instruction cache
            // ever so slightly but is seen to help in benchmarks.
            .i386, .x86_64 => {
                return atomic.bitSet(
                    &self.state,
                    @ctz(u1, LOCKED),
                    .acquire
                ) == UNLOCKED;
            },
            else => {
                return atomic.swap(
                    @ptrCast(*u8, self.state),
                    LOCKED,
                    .acquire,
                ) == UNLOCKED;
            },
        }
    }

    /// Acquire ownership of the Lock, using the Event to implement blocking.
    pub fn acquire(self: *Lock, comptime Event: type) void {
        if (!self.tryAcquire())
            self.acquireSlow(Event);
    }
    
    /// Release ownership of the Lock, assuming already acquired.
    pub fn release(self: *Lock) void {
        atomic.store(
            @ptrCast(*u8, &self.state),
            UNLOCKED,
            .release,
        );

        // NOTE: we could also check if its not locked or waking
        // but its slightly better to keep the i-cache hit smaller.
        const state = atomic.load(&self.state, .relaxed);
        if (state & WAITING != 0)
            self.releaseSlow();
    }

    fn acquireSlow(self: *Lock, comptime Event: type) void {
        @setCold(true);

        // This type bundles the Event (wakeup mechanism) with the Waiter node.
        var event_waiter: struct {
            event: Event,
            waiter: Waiter,

            fn wake(waiter: *Waiter) void {
                const this = @fieldParentPtr(@This(), "waiter", waiter);
                this.event.notify();
            }
        } = undefined;
        
        // Use lazy initialization for the event
        var has_event = false;
        defer if (has_event) 
            event_waiter.event.deinit();

        var spin_iter: usize = 0;
        var state = atomic.load(&self.state, .relaxed);
        while (true) {
            
            // Try to acquire the lock if its unlocked.
            if (state & LOCKED == 0) {
                if (self.tryAcquire())
                    return;
                _ = Event.yield(null);
                state = atomic.load(&self.state, .relaxed);
                continue;
            }
            
            // If its locked, spin on it using the Event if theres no waiters.
            const head = @intToPtr(?*Waiter, state & WAITING);
            if (head == null and Event.yield(spin_iter)) {
                spin_iter +%= 1;
                state = atomic.load(&self.state, .relaxed);
                continue;
            }
            
            // The lock is contended, prepare our waiter to be enqueued at the head.
            // The first waiter to be enqueued sets its tail to itself.
            //  This is needed later in release().
            const waiter = &event_waiter.waiter;
            waiter.prev = null;
            waiter.next = head;
            waiter.tail = if (head == null) waiter else null;
            waiter.wakeFn = @TypeOf(event_waiter).wake;

            // Lazily initialize the Event object to prepare for waiting.
            const event = &event_waiter.event;
            if (!has_event) {
                has_event = true;
                event.init();
            }

            // Push this waiter to the head of the wait list.
            //
            // Release ordering on success to ensure release() thread 
            // which Acquire loads sees our Waiter/Event writes above.
            if (atomic.tryCompareAndSwap(
                &self.state,
                state,
                (state & ~WAITING) | @ptrToInt(waiter),
                .release,
                .relaxed,
            )) |updated| {
                state = updated;
                continue;
            }

            event.wait(null) catch unreachable;
            event.reset();
            spin_iter = 0;


            // Use `fetchSub` on x86 as it can be done without a `lock cmpxchg` loop.
            // Use `fetchAnd` for others as bitwise ops are generally less expensive than common arithmetic.
            state = switch (builtin.arch) {
                .i386, .x86_64 => atomic.fetchSub(&self.state, WAKING, .relaxed),
                else => atomic.fetchAnd(&self.state, ~@as(usize, WAKING), .relaxed),
            };
            state &= ~@as(usize, WAKING);
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        // Try to grab the WAKING bit, bailing under a few conditions:
        // - bail if theres no waiters to wake
        // - bail if the LOCKED bit is held, the locker will do the wake
        // - bail if the WAKING bit is held, theres already a thread waking.
        //
        // Acquire ordering on success as we'll be deferencing the Waiter from the state 
        // and need to see its writes published by Release above when enqueued.
        //
        // Consume ordering to be precise which provides Acquire guarantees but with the
        // possibility of less synchronization overhead since the memory we're Acquiring
        // is derived from the atomic variable (state) itself.
        var state = atomic.load(&self.state, .relaxed);
        while (true) {
            if ((state & WAITING == 0) or (state & (LOCKED | WAKING) != 0))
                return;
            state = atomic.tryCompareAndSwap(
                &self.state,
                state,
                state | WAKING,
                .consume,
                .relaxed,
            ) orelse break;
        }

        state |= WAKING;
        while (true) {
            // Compute the head and the tail of the wait queue
            // so we can dequeue and wake up the tail waiter.
            //
            // - The head is guaranteed to be non-null due to the loop above
            // and due to the fact that the only thread which can zero it is us (WAKING bit).
            //
            // - The tail is queried by following the head Waiter and down its .next chain
            //   until it finds the Waiter with its .tail field set, setting the .prev along the way.
            //
            //   The first waiter enqueued is guaranteed to have its .tail set to itself
            //   and complete the loop as per the code in acquireSlow().
            //
            //   After finding the tail, it is cached at the head node's tail field.
            //   This immediately resolves in future lookups to make the traversal amortized(O(n)) at most.
            const head = @intToPtr(*Waiter, state & WAITING);
            const tail = head.tail orelse blk: {
                var current = head;
                while (true) {
                    const next = current.next orelse unreachable;
                    next.prev = current;
                    current = next;
                    if (current.tail) |tail| {
                        head.tail = tail;
                        break :blk tail;
                    }
                }
            };
            
            // If the LOCKED bit is currently held, 
            // then we should just let the lock holder do the wakeup instead.
            //
            // Release ordering to ensure the head/tail writes we did above are visible to the next waker thread.
            // Acquire/Consume ordering requirement is listed above in grabbing of the WAKING bit.
            if (state & LOCKED != 0) {
                state = atomic.tryCompareAndSwap(
                    &self.state,
                    state,
                    state & ~@as(usize, WAKING),
                    .release,
                    .consume,
                ) orelse return;
                continue;
            }

            // If we aren't the last waiter, then just do a normal dequeue
            // by updating the head's tail reference to denote that we're no longer in the queue.
            //
            // Release ordering to ensure that future WAKING threads see the head.tail update.
            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                atomic.fence(.release);

            // If we *are* the last waiter, we need to zero out the Waiter bits from the state in order to dequeue.
            // At this point, we're also not LOCKED so the only thing we need to leave is the WAKING bit which the tail will unset on wake.
            //
            // Release and Acquire/Consume ordering as explained above.
            // TODO: Is release actually necessary here given no threads see our changes on success?
            } else {
                if (atomic.tryCompareAndSwap(
                    &self.state,
                    state,
                    WAKING,
                    .release,
                    .consume,
                )) |updated| {
                    state = updated;
                    continue;
                }
            }

            (tail.wakeFn)(tail);
            return;
        }
    }
};