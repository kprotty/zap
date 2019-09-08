const std = @import("std");
const builtin = @import("builtin");

pub fn CachePadded(comptime T: type) type {
    return packed struct {
        value: T,
        padding: [@sizeOf(T) % 64]u8,
    };
}

pub fn nextPowerOfTwo(value: var) @typeOf(value) {
    const T = @typeOf(value);
    const Bits = @typeInfo(T).Int.bits;
    const Shr = @log2(f32, @intToFloat(f32, Bits));
    const ShrType = @IntType(false, @floatToInt(u64, Shr));
    return T(1) << @truncate(ShrType, Bits - @clz(T, value - 1));
}

