const std = @import("std");
const builtin = @import("builtin");

pub fn CachePadded(comptime T: type) type {
    return packed struct {
        value: T,
        padding: [@sizeOf(T) % 64]u8,
    };
}

pub fn popCount(value: var) @typeOf(value) {
    const T = @typeOf(value);
    switch (@typeId(T)) {
        .Int => return @popCount(T, value),
        .ComptimeInt => {
            comptime var bits = 0;
            comptime var current = 0;
            comptime var value_bits = value;
            inline while (value_bits > 0) : (value_bits >>= 1) {
                if ((value_bits & 1) != 0)
                    bits = current;
                current += 1;
            }
            return bits;
        },
        else => @compileError("Only supports integers"),
    }
}

pub fn nextPowerOfTwo(value: var) @typeOf(value) {
    const T = @typeOf(value);
    switch (@typeInfo(T)) {
        .Int => |int| {
            const ShrBits = @log2(f32, @intToFloat(f32, int.bits));
            const ShrType = @IntType(false, @floatToInt(u64, ShrBits));
            return T(1) << @truncate(ShrType, int.bits - @clz(T, value - 1));
        },
        .ComptimeInt => {
            const power_of_two = comptime_int(1) << popCount(value);
            return power_of_two << (if (power_of_two < value) 1 else 0);
        },
        else => @compileError("Only supports integers"),
    }
}

