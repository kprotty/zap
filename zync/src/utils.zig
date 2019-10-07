const std = @import("std");
const builtin = @import("builtin");
const atomic = @import("atomic.zig");

pub const cache_line = 64;
pub fn CachePadded(comptime T: type) type {
    return packed struct {
        value: T,
        padding: [std.mem.alignForward(@sizeOf(T), cache_line) - @sizeOf(T)]u8,
    };
}

const expect = std.testing.expect;
test "cache padding" {
    expect(@sizeOf(CachePadded(u9)) == cache_line);
    expect(@sizeOf(CachePadded(u64)) == cache_line);
    expect(@sizeOf(CachePadded([cache_line]u8)) == cache_line);
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

test "popCount" {
    expect(popCount(0b11011) == 4);
    expect(popCount(usize(0b111)) == usize(3));
    expect(popCount(~u64(0)) == @typeInfo(u64).Int.bits);
}

pub fn intType(comptime is_signed: bool, comptime bits: var) type {
    return @Type(builtin.TypeInfo{
        .Int = builtin.TypeInfo.Int{
            .bits = bits,
            .is_signed = is_signed,
        },
    });
}

pub fn shrType(comptime Int: type) type {
    const bits = @typeInfo(Int).Int.bits;
    const log2_bits = @log2(f32, @intToFloat(f32, bits));
    return intType(false, @floatToInt(u64, log2_bits));
}

test "shrType" {
    expect(shrType(u8) == u3);
    expect(shrType(u16) == u4);
    expect(shrType(u32) == u5);
    expect(shrType(u64) == u6);
}

pub fn nextPowerOfTwo(value: var) @typeOf(value) {
    const T = @typeOf(value);
    switch (@typeInfo(T)) {
        .Int => |int| {
            const shift_amount = int.bits - @clz(T, value - 1);
            return T(1) << @truncate(shrType(T), shift_amount);
        },
        .ComptimeInt => {
            const power_of_two = comptime_int(1) << popCount(value);
            return power_of_two << (if (power_of_two < value) 1 else 0);
        },
        else => @compileError("Only supports integers"),
    }
}

test "nextPowerOfTwo" {
    expect(nextPowerOfTwo(9) == 16);
    expect(nextPowerOfTwo(usize(32)) == 32);
    expect(nextPowerOfTwo(u8(127)) == u8(128));
}

pub fn Lazy(initializer: var) type {
    return struct {
        pub const Type = @typeOf(initializer).ReturnType;
        pub const State = enum {
            Uninitialized,
            Initializing,
            Initialized,
        };

        value: Type,
        state: atomic.Atomic(State),

        pub fn new() @This() {
            return @This(){
                .value = undefined,
                .state = atomic.Atomic(State).new(.Uninitialized),
            };
        }

        pub inline fn get(self: *@This()) Type {
            return self.getPtr().*;
        }

        pub fn getPtr(self: *@This()) *Type {
            if (self.state.load(.Relaxed) == .Initialized)
                return &self.value;

            if (self.state.compareSwap(.Uninitialized, .Initializing, .Acquire, .Relaxed)) |_| {
                while (self.state.load(.Acquire) == .Initializing)
                    atomic.yield(1);
                return &self.value;
            }

            self.value = initializer();
            self.state.store(.Initialized, .Release);
            return &self.value;
        }
    };
}

test "lazy init" {
    const Pi = struct {
        var current = Lazy(create).new();
        fn create() f32 {
            expect(current.state.get() == .Initializing);
            return f32(3.14);
        }
    };

    expect(Pi.current.state.get() == .Uninitialized);
    expect(Pi.current.get() == 3.14);
    expect(Pi.current.state.get() == .Initialized);
    expect(Pi.current.get() == 3.14);
}
