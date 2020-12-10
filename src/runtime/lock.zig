const zap = @import("../zap.zig");
const system = zap.runtime.system;
const target = zap.runtime.target;
const atomic = zap.sync.atomic;
const Event = zap.runtime.Event;

pub const Lock = 
    if (target.is_windows)
        WindowsLock
    else if (target.is_posix)
        PosixLock
    else
        @compileError("OS not supported for threading blocking locks");

const WindowsLock = struct {
    srwlock: system.SRWLOCK = system.SRWLOCK_INIT,

    pub fn tryAcquire(self: *Lock) bool {
        return system.TryAcquireSRWLockExclusive(&self.srwlock) == system.TRUE;
    }

    pub fn acquire(self: *Lock) void {
        return system.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn release(self: *Lock) void {
        return system.ReleaseSRWLockExclusive(&self.srwlock);
    }
};

const PosixLock = struct {
    state: usize = UNLOCKED,

    const bit_set = target.is_x86;
    const byte_swap = target.is_x86
        or target.is_arm 
        or target.is_ppc 
        or target.is_riscv
        or switch (target.arch) {
            .s380x => true,
            else => false,
        };

    const UNLOCKED = 0;
    const LOCKED = 1;
    const WAKING = 1 << (if (byte_swap) 8 else 1);
    const WAITING = ~@as(usize, (WAKING << 1) - 1);

    const Waiter = struct {
        prev: ?*Waiter align(~WAITING + 1),
        next: ?*Waiter,
        tail: ?*Waiter,
        event: usize,

        const EVENT_WAITING = 0;
        const EVENT_NOTIFIED = 1;
    };

    pub fn tryAcquire(self: *Lock) bool {
        if (bit_set) {
            return asm volatile(
                "lock btsl $0, %[ptr]"
                : [ret] "={@ccc}" (-> u8),
                : [ptr] "*m" (&self.state)
                : "cc", "memory"
            ) == 0;
        }

        if (byte_swap) {
            return atomic.swap(
                @ptrCast(*u8, &self.state),
                LOCKED,
                .acquire,
            ) == UNLOCKED;
        }

        var state: usize = UNLOCKED;
        while (true) {
            if (state & LOCKED != 0)
                return false;
            state = atomic.tryCompareAndSwap(
                &self.state,
                state,
                state | LOCKED,
                .acquire,
                .relaxed,
            ) orelse return true;
        }
    }

    pub fn acquire(self: *Lock) void {
        if (bit_set or byte_swap) {
            if (self.tryAcquire())
                return;
        } else if (atomic.tryCompareAndSwap(
            &self.state,
            UNLOCKED,
            LOCKED,
            .acquire,
            .relaxed,
        ) == null) {
            return;
        }

        self.acquireSlow();
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        var spin: u8 = 0;
        var waiter: Waiter = undefined;
        var state = atomic.load(&self.state, .relaxed);

        while (true) {
            const try_acquire = state & LOCKED == 0;
            if (try_acquire) {
                if (bit_set or byte_swap) {
                    if (self.tryAcquire())
                        return;
                } else if (atomic.tryCompareAndSwap(
                    state,
                    state | LOCKED,
                    .acquire,
                    .relaxed,
                ) == null) {
                    return;
                }
            }

            const max_spin = 40;
            const head = @intToPtr(?*Waiter, state & WAITING);
            if (try_acquire or (head == null and spin < max_spin)) {
                if (spin <= 5) {
                    var iter = @as(usize, 1) << @intCast(u3, spin);
                    while (iter != 0) : (iter -= 1)
                        atomic.spinLoopHint();
                } else if (target.is_darwin) {
                    _ = system.thread_switch(
                        system.MACH_PORT_NULL,
                        system.SWITCH_OPTION_DEPRESS,
                        @as(system.mac_msg_timeout_t, 1),
                    );
                } else if (target.is_posix) {
                    _ = system.sched_yield();
                }

                spin += if (spin == max_spin) 0 else 1;
                state = atomic.load(&self.state, .relaxed);
                continue;
            }

            waiter.prev = null;
            waiter.next = head;
            waiter.tail = if (head == null) &waiter else null;
            waiter.event = Waiter.EVENT_WAITING;

            if (atomic.tryCompareAndSwap(
                &self.state,
                state,
                (state & ~WAITING) | @ptrToInt(&waiter),
                .release,
                .relaxed,
            )) |updated| {
                state = updated;
                continue;
            }

            var event = Event{};
            _ = event.wait(null, struct {
                wait_ptr: *Waiter,
                event_ptr: *Event,

                pub fn wait(self: @This()) bool {
                    return atomic.swap(
                        &self.wait_ptr.event,
                        @ptrToInt(self.event_ptr),
                        .acq_rel,
                    ) == Waiter.EVENT_WAITING;
                }
            }{
                .wait_ptr = &waiter,
                .event_ptr = &event,
            });

            spin = 0;
            state = atomic.fetchSub(&self.state, WAKING, .relaxed);
            state -= WAKING;
        }
    }

    pub fn release(self: *Lock) void {
        const state = blk: {
            if (byte_swap) {
                atomic.store(@ptrCast(*u8, &self.state), UNLOCKED, .release);
                break :blk atomic.load(&self.state, .relaxed);
            } else {
                break :blk atomic.fetchSub(&self.state, LOCKED, .release);
            }
        };

        if (state & WAITING != 0)
            self.releaseSlow();
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        var state = atomic.load(&self.state, .relaxed);
        while (true) {
            if ((state & WAITING == 0) or (state & (LOCKED | WAKING) != 0))
                return;
            state = atomic.tryCompareAndSwap(
                &self.state,
                state,
                state | WAKING,
                .acquire,
                .relaxed,
            ) orelse {
                state |= WAKING;
                break;
            };
        }

        while (true) {
            const head = @intToPtr(*Waiter, state & WAITING);
            const tail = head.tail orelse blk: {
                var current = head;
                while (true) {
                    const next = current.next orelse unreachable;
                    next.prev = current;
                    next = current;
                    if (current.tail) |tail| {
                        head.tail = tail;
                        break :blk tail;
                    }
                }
            };

            if (state & LOCKED != 0) {
                state = atomic.tryCompareAndSwap(
                    state,
                    state & ~@as(usize, LOCKED),
                    .release,
                    .acquire,
                ) orelse return;
                continue;
            }

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                atomic.fence(.release);
            } else if (atomic.tryCompareAndSwap(
                state,
                WAKING,
                .release,
                .acquire,
            )) |updated| {
                state = updated;
                continue;
            }

            const event_value = atomic.swap(&tail.event, Waiter.EVENT_NOTIFIED, .consume);
            if (@intToPtr(?*Event, event_value)) |event|
                event.notify();
            return;
        }
    }
};