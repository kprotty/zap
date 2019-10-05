const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils.zig");
const mem = @import("zap").zuma.mem;

pub fn yield(spin_count: usize) void {
    var spin = spin_count;
    while (spin > 0) : (spin -= 1) {
        switch (builtin.arch) {
            .i386, .x86_64 => asm volatile("pause" ::: "memory"),
            .arm, .aarch64 => asm volatile("yield"),
            else => _ = @ptrCast(*volatile usize, &spin).*,
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

pub inline fn fence(comptime order: AtomicOrder) void {
    @fence(comptime order.toBuiltin());
}

pub fn Atomic(comptime T: type) type {
    std.debug.assert(@sizeOf(T) > 0);
    std.debug.assert(@sizeOf(T) <= @sizeOf(usize));

    return struct {
        value: Type,

        pub const Type = baseType(T);
        pub const Order = AtomicOrder;

        /// Used for resolved int/float types with weird bit sizes (e.g. u7)
        /// and store them in an atomic-type compatible backing with conversions in and out.
        fn baseType(comptime B: type) type {
            return switch (@typeInfo(B)) {
                .Int => |int| utils.intType(int.is_signed, std.math.max(8, comptime utils.nextPowerOfTwo(int.bits))),
                .Float => |float| utils.intType(false, std.math.max(8, comptime utils.nextPowerOfTwo(float.bits))),
                .Enum => baseType(@TagType(B)),
                .Bool => u8,
                else => utils.intType(false, comptime utils.nextPowerOfTwo(@sizeOf(B) * 8)),
            };
        }
        
        pub fn new(value: T) @This() {
            return @This() { .value = mem.transmute(Type, value) };
        }

        pub inline fn get(self: @This()) T {
            return mem.transmute(T, self.value);
        }

        pub inline fn set(self: *@This(), value: T) void {
            self.value = mem.transmute(Type, value);
        }

        pub inline fn store(self: *@This(), value: T, comptime order: Order) void {
            // TODO: https://github.com/ziglang/zig/issues/2995
            _ = self.swap(value, order);
        }

        pub fn load(self: *@This(), comptime order: Order) T {
            return mem.transmute(T, @atomicLoad(Type, &self.value, comptime order.toBuiltin()));
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

        pub fn compareSwap(self: *@This(), cmp: T, xchg: T, comptime success: Order, comptime failure: Order) ?T {
            return mem.transmute(?T, @cmpxchgWeak(
                Type,
                &self.value,
                mem.transmute(Type, cmp),
                mem.transmute(Type, xchg),
                comptime success.toBuiltin(),
                comptime failure.toBuiltin(),
            ));
        }

        pub fn compareSwapStrong(self: *@This(), cmp: T, xchg: T, comptime success: Order, comptime failure: Order) ?T {
            return mem.transmute(?T, @cmpxchgStrong(
                Type,
                &self.value,
                mem.transmute(Type, cmp),
                mem.transmute(Type, xchg),
                comptime success.toBuiltin(),
                comptime failure.toBuiltin(),
            ));
        }

        fn atomicRmw(self: *@This(), value: T, comptime op: builtin.AtomicRmwOp, comptime order: Order) T {
            return mem.transmute(T, @atomicRmw(
                Type,
                &self.value,
                op,
                mem.transmute(Type, value),
                comptime order.toBuiltin(),
            ));
        }
    };
}

const expect = std.testing.expect;

test "yield, fence" {
    fence(.Release);
    _ = yield(69);
    fence(.Acquire);
}

test "size rounding" {
    expect(Atomic(struct { x: usize }).Type == utils.intType(false, @typeInfo(usize).Int.bits));
    expect(Atomic(enum(u2) { X, Y }).Type == u8);
    expect(Atomic(u42).Type == u64);
    expect(Atomic(u64).Type == u64);
}

test "get, set, load, store, swap, compareSwap" {
    var f = Atomic(f32).new(3.14);
    expect(f.get() == 3.14);

    var e = Atomic(enum { A, B, C, D, E }).new(.A);
    expect(e.get() == .A);
    e.set(.B);
    expect(e.load(.Relaxed) == .B);
    e.store(.C, .Relaxed);
    expect(e.swap(.D, .Relaxed) == .C);
    expect(e.compareSwap(.D, .E, .Relaxed, .Relaxed) == null);
    expect(e.get() == .E);
}

test "add, sub, and, nand, or, xor, min, max" {
    var n = Atomic(u8).new(0);
    expect(n.fetchAdd(4, .Relaxed) == 0);           // n = 0 ADD 4 = 4
    expect(n.fetchSub(1, .Relaxed) == 4);           // n = 4 SUB 1 = 3
    expect(n.fetchAnd(2, .Relaxed) == 3);           // n = 3(0b11) AND 2(0b10) = 2(0b10)
    expect(n.fetchNand(2, .Relaxed) == 2);          // n = 2(0b00000010) NAND 2 = 0b11111101
    expect(n.fetchOr(2, .Relaxed) == ~u8(2));       // n = 0b11111101 OR 0b00000010 = 0b11111111
    expect(n.fetchXor(~u8(0), .Relaxed) == ~u8(0)); // n = 0b11111111 XOR 0b11111111 = 0
    expect(n.min(1, .Relaxed) == 0);                // n = (0 < 1) ? 0 : 1 = 0
    expect(n.max(1, .Relaxed) == 0);                // n = (1 > 0) ? 1 : 0 = 1
    expect(n.load(.Relaxed) == 1);
} 