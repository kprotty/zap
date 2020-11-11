// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const builtin = @import("builtin");
const core = @import("../core.zig");

pub fn spinLoopHint() void {
    if (core.is_x86) {
        asm volatile("pause");
    } else if (core.is_arm) {
        asm volatile("yield");
    }
}

pub const Ordering = enum {
    unordered,
    relaxed,
    consume,
    acquire,
    release,
    acq_rel,
    seq_cst,

    pub fn asRmwLoad(comptime self: Ordering) Ordering {
        return switch (self) {
            .unordered => @compileError("atomic rmw operations don't support .unordered memory orderings"),
            .relaxed, .consume, .acquire => self,
            .release => .relaxed,
            .acq_rel => .acquire,
            .seq_cst => .seq_cst,
        };
    }

    pub fn asRmwStore(comptime self: Ordering) Ordering {
        return switch (self) {
            .unordered => @compileError("atomic rmw operations don't support .unordered memory orderings"),
            .relaxed, .consume, .acquire => .relaxed,
            .release, .acq_rel => .release,
            .seq_cst => .seq_cst,
        };
    }

    pub fn isConsumeAcquire(comptime self: Ordering) bool {
        return switch (core.arch_type) {
            .i386, .x86_64, .arm, .aarch64, .powerpc, .powerpc64, .powerpc64le => false,
            else => true,
        };
    }
    
    fn toBuiltin(comptime self: Ordering) builtin.AtomicOrder {
        return switch (self) {
            .unordered => .Unordered,
            .consume => if (self.isConsumeAcquire()) .Acquire else .Monotonic,
            .relaxed => .Monotonic,
            .acquire => .Acquire,
            .release => .Release,
            .acq_rel => .AcqRel,
            .seq_cst => .SeqCst,
        };
    }
};

pub fn fence(comptime ordering: Ordering) void {
    @fence(comptime ordering.toBuiltin());
}

pub fn compilerFence(comptime ordering: Ordering) void {
    asm volatile("" ::: "memory");
}

pub fn Atomic(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return Self{ .value = value };
        }

        pub fn get(self: Self) T {
            return self.value;
        }

        pub fn set(self: *Self, value: T) void {
            self.value = value;
        }

        pub fn load(self: *const Self, comptime ordering: Ordering) T {
            return @atomicLoad(T, &self.value, comptime ordering.toBuiltin());
        }

        pub fn store(self: *Self, value: T, comptime ordering: Ordering) void {
            return @atomicStore(T, &self.value, value, comptime ordering.toBuiltin());
        }

        pub fn swap(self: *Self, value: T, comptime ordering: Ordering) T {
            return @atomicRmw(T, &self.value, .Xchg, value, comptime ordering.toBuiltin());
        }

        pub fn fetchAdd(self: *Self, value: T, comptime ordering: Ordering) T {
            return @atomicRmw(T, &self.value, .Add, value, comptime ordering.toBuiltin());
        }

        pub fn fetchSub(self: *Self, value: T, comptime ordering: Ordering) T {
            return @atomicRmw(T, &self.value, .Sub, value, comptime ordering.toBuiltin());
        }

        pub fn fetchAnd(self: *Self, value: T, comptime ordering: Ordering) T {
            return @atomicRmw(T, &self.value, .And, value, comptime ordering.toBuiltin());
        }

        pub fn fetchOr(self: *Self, value: T, comptime ordering: Ordering) T {
            return @atomicRmw(T, &self.value, .Or, value, comptime ordering.toBuiltin());
        }

        pub fn compareAndSwap(self: *Self, cmp: T, xchg: T, comptime success: Ordering, comptime failure: Ordering) ?T {
            return @cmpxchgStrong(T, &self.value, cmp, xchg, comptime success.toBuiltin(), comptime failure.toBuiltin());
        }

        pub fn tryCompareAndSwap(self: *Self, cmp: T, xchg: T, comptime success: Ordering, comptime failure: Ordering) ?T {
            return @cmpxchgWeak(T, &self.value, cmp, xchg, comptime success.toBuiltin(), comptime failure.toBuiltin());
        }

        pub fn fetchBit(self: *Self, bit: core.math.Log2Int(T), comptime ordering: Ordering) u1 {
            return self.atomicBitwise(.get, bit, ordering);
        }

        pub fn fetchBitAndSet(self: *Self, bit: core.math.Log2Int(T), comptime ordering: Ordering) u1 {
            return self.atomicBitwise(.set, bit, ordering);
        }

        pub fn fetchBitAndReset(self: *Self, bit: core.math.Log2Int(T), comptime ordering: Ordering) u1 {
            return self.atomicBitwise(.reset, bit, ordering);
        }

        pub fn fetchBitAndToggle(self: *Self, bit: core.math.Log2Int(T), comptime ordering: Ordering) u1 {
            return self.atomicBitwise(.toggle, bit, ordering);
        }

        const BitwiseOp = enum {
            get,
            set,
            reset,
            toggle,
        };

        fn atomicBitwise(self: *Self, comptime op: BitwiseOp, bit: core.math.Log2Int(T), comptime ordering: Ordering) u1 {
            if (@typeInfo(T) != .Int) {
                @compileError("Atomic(" ++ T ++ ") does not support bitwise operations");
            }

            const mask = @as(T, 1) << bit;
            const bits = core.meta.bitCount(T);
            
            if (core.is_x86 and bits <= core.meta.bitCount(usize)) {
                const instruction: []const u8 = switch (op) {
                    .get => "bt",
                    .set => "lock bts",
                    .reset => "lock btr",
                    .toggle => "lock btc",
                };

                // x86 address faults are by page: if at least one byte is valid, the operation succeeds.
                // x86 bitwise ops only support as low as 16-bit/word instructions 
                //      so we take advantage of the page faulting for T of size < u16
                const suffix: []const u8 = 
                    if (bits <= core.meta.bitCount(u16)) "w"
                    else if (bits <= core.meta.bitCount(u32)) "l"
                    else if (bits <= core.meta.bitCount(u16)) "q"
                    else unreachable;

                const ptr_bit = asm volatile(
                    instruction ++ suffix ++ " %[bit], %[ptr]"
                    : [ptr_bit] "={@ccc}" (-> u8)
                    : [ptr] "*p" (&self.value)
                      [bit] "X" (bit)
                    : "cc", "memory"
                );

                @setRuntimeSafety(false);
                return @intCast(u1, ptr_bit);
            }

            const value = switch (op) {
                .get => self.load(comptime ordering.asRmwLoad()),
                .set => self.fetchOr(mask, ordering),
                .reset => self.fetchAnd(~mask, ordering),
                .toggle => self.fetchXor(mask, ordering),
            };

            return @boolToInt(value & mask != 0);
        }
    };
}
