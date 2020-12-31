const zap = @import("../zap");
const builtin = zap.builtin;
const meta = zap.meta;

const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;
const AtomicBitOp = enum {
    Get,
    Set,
    Reset,
    Toggle,
};

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

    fn toBuiltin(comptime self: Ordering) AtomicOrder {
        return switch (self) {
            .unordered => .Unordered,
            .relaxed => .Monotonic,
            .consume => .Acquire, // TODO: relaxed + compilerFence(.acquire) ?
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
        .unordered => @compileError("Unordered memory ordering can only be on atomic variables"),
        .relaxed => @compileError("Relaxed memory ordering can only be on atomic variables"),
        .consume => @compileError("Consume memory ordering can only be on atomic variables"),
        else => asm volatile("" ::: "memory"),
    }
}

pub fn load(ptr: anytype, comptime ordering: Ordering) @TypeOf(ptr.*) {
    return @atomicLoad(@TypeOf(ptr.*), ptr, comptime ordering.toBuiltin());
}

pub fn store(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) void {
    return @atomicStore(@TypeOf(ptr.*), ptr, value, comptime ordering.toBuiltin());
}

pub fn swap(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Xchg, value, ordering);
}

pub fn fetchAdd(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Add, value, ordering);
}

pub fn fetchSub(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Sub, value, ordering);
}

pub fn fetchAnd(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .And, value, ordering);
}

pub fn fetchOr(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Or, value, ordering);
}

pub fn fetchXor(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Xor, value, ordering);
}

inline fn atomicRmw(comptime T: type, ptr: *T, comptime op: AtomicRmwOp, value: T, comptime ordering: Ordering) T {
    return @atomicRmw(T, ptr, op, value, comptime ordering.toBuiltin());
}

pub fn compareAndSwap(ptr: anytype, cmp: @TypeOf(ptr.*), xchg: @TypeOf(ptr.*), comptime success: Ordering, comptime failure: Ordering) ?@TypeOf(ptr.*) {
    return @cmpxchgStrong(@TypeOf(ptr.*), ptr, cmp, xchg, comptime success.toBuiltin(), comptime failure.toBuiltin());
}

pub fn tryCompareAndSwap(ptr: anytype, cmp: @TypeOf(ptr.*), xchg: @TypeOf(ptr.*), comptime success: Ordering, comptime failure: Ordering) ?@TypeOf(ptr.*) {
    return @cmpxchgStrong(@TypeOf(ptr.*), ptr, cmp, xchg, comptime success.toBuiltin(), comptime failure.toBuiltin());
}

pub fn bitGet(ptr: anytype, bit: meta.Log2Int(@TypeOf(ptr.*)), comptime ordering: Ordering) u1 {
    return atomicBit(@TypeOf(ptr.*), ptr, .Get, bit, ordering);
}

pub fn bitSet(ptr: anytype, bit: meta.Log2Int(@TypeOf(ptr.*)), comptime ordering: Ordering) u1 {
    return atomicBit(@TypeOf(ptr.*), ptr, .Set, bit, ordering);
}

pub fn bitReset(ptr: anytype, bit: meta.Log2Int(@TypeOf(ptr.*)), comptime ordering: Ordering) u1 {
    return atomicBit(@TypeOf(ptr.*), ptr, .Reset, bit, ordering);
}

pub fn bitToggle(ptr: anytype, bit: meta.Log2Int(@TypeOf(ptr.*)), comptime ordering: Ordering) u1 {
    return atomicBit(@TypeOf(ptr.*), ptr, .Toggle, bit, ordering);
}

fn atomicBit(comptime T: type, ptr: *T, comptime op: AtomicBitOp, bit: meta.Log2Int(T), comptime ordering: Ordering) u1 {
    const bytes = @sizeOf(T);
    const mask = @as(T, 1) << bit;
    const is_x86 = switch (builtin.arch) {
        .i386, .x86_64 => true,
        else => false,
    };

    if (is_x86 and (op != .Get) and (bytes <= @sizeOf(usize))) {
        const instruction: []const u8 = switch (op) {
            .Get => unreachable,
            .Set => "lock bts",
            .Reset => "lock btr",
            .Toggle => "lock btc",
        };

        const suffix: []const u8 = switch (bytes) {
            // on x86, faults are by page. If at least one byte is valid, operation will succeed.
            1, 2 => "w", 
            4 => "l",
            8 => "q",
            else => unreachable,
        };

        const Bit = meta.Int(
            .unsigned,
            meta.max(2, bytes) * 8,
        );

        return @intCast(u1, asm volatile(
            instruction ++ suffix ++ " %[bit], %[ptr]"
            : [result] "={@ccc}" (-> u8)
            : [ptr] "*p" (ptr),
              [bit] "X" (@as(Bit, bit))
            : "cc", "memory"
        ));
    }

    const value = switch (op) {
        .Get => load(ptr, ordering),
        .Set => fetchOr(ptr, mask, ordering),
        .Reset => fetchAnd(ptr, ~mask, ordering),
        .Toggle => fetchXor(ptr, mask, ordering),
    };

    return @boolToInt(value & mask != 0);
}