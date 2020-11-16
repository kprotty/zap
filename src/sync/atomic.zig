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
    acquire,
    release,
    acq_rel,
    seq_cst,
    
    fn toBuiltin(comptime self: Ordering) builtin.AtomicOrder {
        return switch (self) {
            .unordered => .Unordered,
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
    };
}