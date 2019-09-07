const std = @import("std");
const builtin = @import("builtin");

pub fn CachePadded(comptime T: type) type {
    return packed struct {
        value: T,
        padding: [64 - @sizeOf(T)]u8,
    };
}

pub fn nextPowerOfTwo(value: var) @typeOf(value) {
    const T = @typeOf(value);
    const Bits = @typeInfo(T).Int.bits;
    const Shr = @log2(f32, @intToFloat(f32, Bits));
    const ShrType = @IntType(false, @floatToInt(u64, Shr));
    return T(1) << @truncate(ShrType, Bits - @clz(T, value - 1));
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

pub fn Atomic(comptime T: type) type {
    std.debug.assert(@sizeOf(T) > 0);
    std.debug.assert(@sizeOf(T) <= @sizeOf(usize));

    return struct {
        value: Type,

        pub const Type = baseType();
        pub const Order = AtomicOrder;

        fn baseType() type {
            return switch (@typeInfo(T)) {
                .Int => |int| @IntType(int.is_signed, comptime nextPowerOfTwo(int.bits)),
                .Float => |float| @IntType(false, comptime nextPowerOfTwo(float.bits)),
                .Bool => u8,
                else => T,
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
            var input = from;
            var value: To = undefined;
            @memcpy(@ptrCast([*]u8, &value), @ptrCast([*]const u8, &input), @sizeOf(To));
            return value;
        }
    };
}