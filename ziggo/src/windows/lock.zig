const std = @import("std");
const windows = @import("./windows.zig");
const KeyedEvent = @import("./signal.zig").KeyedEvent;

pub const Lock = 
    if (comptime windows.isOSVersionOrHigher(.vista))
        extern struct {
            srwlock: windows.SRWLOCK = windows.SRWLOC_INIT,

            pub fn acquire(self: *Lock) void {
                windows.AcquireSRWLockExclusive(&self.srwlock);
            }

            pub fn release(self: *Lock) void {
                windows.ReleaseSRWLockExclusive(&self.srwlock);
            }
        }
    else
        extern struct {
            const UNLOCKED = 0 << 0;
            const LOCKED = 1 << 0;
            const WAKING: u32 = 1 << 8;
            const WAITING: u32 = 1 << 9;

            state: u32 = UNLOCKED,

            inline fn tryAcquire(self: *Lock) bool {
                return switch (std.builtin.arch) {
                    .i386, .x86_64 => asm volatile(
                        \\ lock btsl $0, %[state]
                        \\ setnc %[bit_is_now_set]
                        : [bit_is_now_set] "=r" (-> bool)
                        : [state] "*m" (&self.state)
                        : "cc", "memory"
                    ),
                    else => @cmpxchgWeak(
                        u8,
                        @ptrCast(*u8, &self.state),
                        UNLOCKED,
                        LOCKED,
                        .Acquire,
                        .Monotonic,
                    ) == null,
                };
            }

            pub fn acquire(self: *Lock) void {
                if (!self.tryAcquire())
                    self.acquireSlow();
            }

            fn acquireSlow(self: *Lock) void {
                @setCold(true);

                const handle = KeyedEvent.getHandle() orelse self.acquireSpinning();
                var spin: std.math.Log2Int(usize) = 0;
                var state = @atomicLoad(u32, &self.state, .Monotonic);

                while (true) {
                    if (state & LOCKED == 0) {
                        if (self.tryAcquire())
                            return;
                        spin = 0;
                        continue;
                    }

                    if (spin <= 5) {
                        spin += 1;
                        system.spinLoopHint(@as(usize, 1) << spin);
                        state = @atomicLoad(u32, &self.state, .Monotonic);
                        continue;
                    }

                    state = @cmpxchgWeak(
                        u32,
                        &self.state,
                        state,
                        state + WAITING,
                        .Monotonic,
                        .Monotonic,
                    ) orelse blk: {
                        spin = 0;
                        KeyedEvent.wait(handle, &self.state, null) catch unreachable;
                        break :blk @atomicRmw(u32, &self.state, .Sub, WAKING, .Monotonic) - WAKING;
                    };
                }
            }

            fn acquireSpinning(self: *Lock) void {
                @setCold(true);

                var sleep_ms: windows.DWORD = 0;
                while (true) {
                    const state = @atomicLoad(u8, @ptrCast(*const u8, &self.state), .Monotonic);
                    if (state == UNLOCKED) {
                        if (self.tryAcquire())
                            return;
                        sleep_ms = 0;
                    } else {
                        windows.kernel32.Sleep(sleep_ms);
                        sleep_ms = std.math.min(sleep_ms + 1, 10);
                    }
                }
            }

            pub fn release(self: *Lock) void {
                @atomicStore(u8, @ptrCast(*u8, &self.state), UNLOCKED, .Release);

                var state = @atomicLoad(u32, &self.state, .Monotonic);
                if ((state >= WAITING) and (state & (WAKING | LOCKED) == 0))
                    self.releaseSlow(state);
            }

            fn releaseSlow(self: *Lock, current_state: u32) void {
                @setCold(true);

                var state = current_state;
                while (true) {
                    if ((state < WAITING) or (state & (WAKING | LOCKED) != 0))
                        return;
                    state = @cmpxchgWeak(
                        u32,
                        &self.state,
                        state,
                        (state - WAITING) | WAKING,
                        .Monotonic,
                        .Monotonic,
                    ) orelse break;
                }

                const handle = KeyedEvent.getHandle() orelse unreachable;
                KeyedEvent.notify(handle, &self.state);
            }
        };