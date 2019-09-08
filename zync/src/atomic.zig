pub fn yield(spin_count: usize) void {
    var spin = spin_count;
    while (spin > 0) : (spin -= 1) {
        switch (builtin.arch) {
            .i386, .x86_64 => asm volatile("pause" ::: "memory"),
            .arm, .aarch64 => asm volatile("yield"),
            else => // TODO
        }
    }
}

pub const AtomicOrder = enum {
    Relaxed,
    Consume,
    Acquire,
    Release,
    AcqRel,
    SeqCst,

    pub fn toBuiltin(self: @This()) builtin.AtomicOrder {
        return switch (self) {
            .Relaxed => .Monotonic,
            .Consume => .Acquire,
            .Acquire => .Acquire,
            .Release => .Release,
            .AcqRel => .AcqRel,
            .SeqCst => .SeqCst,
        };
    }
};

pub inline fn Fence(comptime order: AtomicOrder) void {
    @fence(comptime order.toBuiltin());
}

pub fn Atomic(comptime T: type) type {
    std.debug.assert(@sizeOf(T) > 0);
    std.debug.assert(@sizeOf(T) <= @sizeOf(usize));

    return struct {
        value: Type,

        pub const Type = baseType(T);
        pub const Order = AtomicOrder;

        fn baseType(comptime B: type) type {
            return switch (@typeInfo(B)) {
                .Int => |int| @IntType(int.is_signed, comptime nextPowerOfTwo(int.bits)),
                .Float => |float| @IntType(false, comptime nextPowerOfTwo(float.bits)),
                .Enum => baseType(@TagType(B)),
                .Bool => u8,
                else => @IntType(false, comptime nextPowerOfTwo(@sizeOf(B) * 8)),
            };
        }
        
        pub fn new(value: T) @This() {
            return @This() { .value = transmute(Type, value) };
        }

        pub inline fn get(self: @This()) T {
            return transmute(Type, self.value);
        }

        pub inline fn set(self: *@This(), value: T) void {
            self.value = transmute(Type, value);
        }

        pub inline fn store(self: *@This(), value: T, comptime order: Order) void {
            // TODO: https://github.com/ziglang/zig/issues/2995
            return self.swap(value, order);
        }

        pub fn load(self: *@This(), comptime order: Order) T {
            return transmute(T, @atomicLoad(Type, &self.value, comptime order.toBuiltin()));
        }

        pub fn swap(self: *@This(), value: T, comptime order: Order) T {
            return self.atomicRmw(value, .Xchg, order);
        }

        pub fn fetchAdd(self: *@This(), value: T, comptime order: Order) T {
            return self.atomicRmw(value, .Add, order);
        }

        pub fn fetchSub(self: *@This(), value: T, comptime order: Order) T {
            return self.atomicRmw(value, .Sub, order);
        }

        pub fn fetchAnd(self: *@This(), value: T, comptime order: Order) T {
            return self.atomicRmw(value, .And, order);
        }

        pub fn fetchNand(self: *@This(), value: T, comptime order: Order) T {
            return self.atomicRmw(value, .Nand, order);
        }

        pub fn fetchOr(self: *@This(), value: T, comptime order: Order) T {
            return self.atomicRmw(value, .Or, order);
        }

        pub fn fetchXor(self: *@This(), value: T, comptime order: Order) T {
            return self.atomicRmw(value, .Xor, order);
        }

        pub fn max(self: *@This(), value: T, comptime order: Order) T {
            return self.atomicRmw(value, .Max, order);
        }

        pub fn min(self: *@This(), value: T, comptime order: Order) T {
            return self.atomicRmw(value, .Min, order);
        }

        pub fn casWeak(self: *@This(), cmp: T, xchg: T, comptime success: Order, comptime failure: Order) ?T {
            return transmute(?T, @cmpxchgWeak(
                Type,
                &self.value,
                transmute(Type, cmp),
                transmute(Type, xchg),
                comptime success.toBuiltin(),
                comptime failure.toBuiltin(),
            ));
        }

        pub fn casStrong(self: *@This(), cmp: T, xchg: T, comptime success: Order, comptime failure: Order) ?T {
            return transmute(?T, @cmpxchgStrong(
                Type,
                &self.value,
                transmute(Type, cmp),
                transmute(Type, xchg),
                comptime success.toBuiltin(),
                comptime failure.toBuiltin(),
            ));
        }

        inline fn atomicRmw(self: *@This(), value: T, comptime op: builtin.AtomicRmwOp, comptime order: Order) T {
            return transmute(T, @atomicRmw(
                Type,
                &self.value,
                op,
                transmute(Type, value),
                comptime order.toBuiltin(),
            ));
        }

        inline fn transmute(comptime To: type, from: var) To {
            return (
                extern union {
                    output: To,
                    input: @typeOf(from),
                } {
                    .input = from,
                }
            ).output;
        }
    };
}