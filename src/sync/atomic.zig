const builtin = @import("builtin");

pub fn spinLoopHint() void {
    switch (builtin.arch) {
        .i386, .x86_64 => asm volatile("pause"),
        .arm, .aarch64 => asm volatile("yield"),
        else => {},
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

    fn toBuiltin(comptime self: Ordering) builtin.AtomicOrder {
        return switch (self) {
            .unordered => .Unordered,
            .relaxed => .Monotonic,
            .consume => .Acquire,
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
    switch (ordering) {
        .unordered, .relaxed, .consume => @compileError(ordering ++ " are for atomic variables only"),
        else => asm volatile("" ::: "memory"),
    }
}

pub fn Atomic(comptime T: type) type {
    return struct {
        value: Value,

        const Self = @This();
        const Value = @Type(builtin.TypeInfo.Int{
            .is_signed = false,
            .bits = @sizeOf(T) * 8,
        });

        pub fn init(value: T) Self {
            return .{ .value = @bitCast(Value, value) };
        }

        inline fn ptr(self: *Self) *T {
            return @ptrCast(*T, &self.value);
        }

        inline fn ptrConst(self: *const Self) *const T {
            return @ptrCast(*const T, &self.value);
        }

        pub fn get(self: Self) T {
            return self.ptrConst().*;
        }

        pub fn set(self: *Self, value: T) void {
            self.ptr().* = value;
        }

        pub fn load(self: *const Self, comptime ordering: Ordering) T {
            return @atomicLoad(T, self.ptrConst(), comptime ordering.toBuiltin());
        }

        pub fn store(self: *Self, value: T, comptime ordering: Ordering) void {
            return @atomicStore(T, self.ptr(), value, comptime ordering.toBuiltin());
        }

        pub fn swap(self: *Self, value: T, comptime ordering: Ordering) T {
            return self.rmw(.Xchg, value, ordering);
        }

        pub fn fetchAdd(self: *Self, value: T, comptime ordering: Ordering) T {
            return self.rmw(.Add, value, ordering);
        }

        pub fn fetchSub(self: *Self, value: T, comptime ordering: Ordering) T {
            return self.rmw(.Sub, value, ordering);
        }

        pub fn fetchAnd(self: *Self, value: T, comptime ordering: Ordering) T {
            return self.rmw(.And, value, ordering);
        }

        pub fn fetchOr(self: *Self, value: T, comptime ordering: Ordering) T {
            return self.rmw(.Or, value, ordering);
        }

        inline fn rmw(self: *Self, comptime op: builtin.AtomicRmwOp, value: T, comptime ordering: Ordering) T {
            return @atomicRmw(T, self.ptr(), op, value, comptime ordering.toBuiltin());
        }

        pub fn compareAndSwap(self: *Self, cmp: T, xchg: T, comptime success: Ordering, comptime failure: Ordering) ?T {
            return @cmpxchgStrong(T, self.ptr(), cmp, xchg, comptime success.toBuiltin(), comptime failure.toBuiltin());
        }

        pub fn tryCompareAndSwap(self: *Self, cmp: T, xchg: T, comptime success: Ordering, comptime failure: Ordering) ?T {
            return @cmpxchgWeak(T, self.ptr(), cmp, xchg, comptime success.toBuiltin(), comptime failure.toBuiltin());
        }
    };
}