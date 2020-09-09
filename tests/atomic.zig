// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const zap = @import("zap");

const Atomic = zap.core.sync.Atomic;
const Ordering = Atomic.Ordering;
const Strength = Atomic.Strength;

test "Atomic.spinLoopHint" {
    _ = Atomic.spinLoopHint();
}

test "Atomic.[compiler]fence" {
    inline for ([_]Ordering{.acquire, .release, .acq_rel, .seq_cst}) |ordering| {
        Atomic.fence(ordering);
        Atomic.compilerFence(ordering);
    }
}

test "Atomic.load" {
    comptime var bits = std.meta.bitCount(usize);
    inline while (bits != 0 and bits >= std.meta.bitCount(u8)) : (bits >>= 1) {
        const Int = std.meta.Int(false, bits);
        inline for ([_]Ordering{.unordered, .relaxed, .consume, .acquire, .seq_cst}) |ordering| {

            const expected: Int = 10;
            var value = expected;
            std.testing.expectEqual(expected, Atomic.load(&value, ordering));
        }
    }
}

test "Atomic.store" {
    comptime var bits = std.meta.bitCount(usize);
    inline while (bits != 0 and bits >= std.meta.bitCount(u8)) : (bits >>= 1) {
        const Int = std.meta.Int(false, bits);
        inline for ([_]Ordering{.unordered, .relaxed, .release, .seq_cst}) |ordering, i| {

            var value: Int = 0;
            const expected: Int = 10;
            Atomic.store(&value, expected + i, ordering);
            std.testing.expectEqual(value, expected + i);
        }
    }
}

test "Atomic.update" {
    comptime var bits = std.meta.bitCount(usize);
    inline while (bits != 0 and bits >= std.meta.bitCount(u8)) : (bits >>= 1) {
        const Int = std.meta.Int(false, bits);
        inline for ([_]Ordering{.relaxed, .acquire, .release, .acq_rel, .seq_cst}) |ordering| {

            var value: Int = 0;
            std.testing.expectEqual(@as(Int, 0), Atomic.update(&value, .swap, 1, ordering));
            std.testing.expectEqual(@as(Int, 1), Atomic.update(&value, .add, 1, ordering));
            std.testing.expectEqual(@as(Int, 2), Atomic.update(&value, .sub, 1, ordering));
            std.testing.expectEqual(@as(Int, 1), Atomic.update(&value, .@"and", 2, ordering));
            std.testing.expectEqual(@as(Int, 0), Atomic.update(&value, .@"or", 1, ordering));
            std.testing.expectEqual(@as(Int, 1), Atomic.update(&value, .nand, 1, ordering));
            std.testing.expectEqual(~@as(Int, 1), Atomic.update(&value, .xor, value|1, ordering));
            std.testing.expectEqual(@as(Int, 1), Atomic.update(&value, .min, 0, ordering));
            std.testing.expectEqual(@as(Int, 0), Atomic.update(&value, .max, ~@as(Int, 0), ordering));
            std.testing.expectEqual(~@as(Int, 0), value);
        }
    }
}

test "Atomic.compareAndSwap" {
    comptime var bits = std.meta.bitCount(u8);
    inline while (bits != 0 and bits >= std.meta.bitCount(u8)) : (bits >>= 1) {
        const Int = std.meta.Int(false, bits);
        inline for ([_][2]Ordering{
            [_]Ordering{.relaxed, .relaxed},
            [_]Ordering{.acquire, .relaxed},
            [_]Ordering{.release, .relaxed},
            [_]Ordering{.acquire, .acquire},
            [_]Ordering{.release, .acquire},
            [_]Ordering{.acq_rel, .acquire},
            [_]Ordering{.seq_cst, .relaxed},
            [_]Ordering{.seq_cst, .acquire},
            [_]Ordering{.seq_cst, .seq_cst},
        }) |ordering| {
            inline for ([_]Strength{.weak, .strong}) |strength| {

                var value: Int = 0;
                const expected: Int = value + 1;
                std.testing.expectEqual(@as(?Int, null), Atomic.compareAndSwap(
                    strength,
                    &value,
                    value,
                    expected,
                    ordering[0],
                    ordering[1],
                ));
                std.testing.expectEqual(expected, value);
            }
        }
    }
}

test "Atomic.bitwise.get" {
    comptime var bits = std.meta.bitCount(usize);
    inline while (bits != 0 and bits >= std.meta.bitCount(u8)) : (bits >>= 1) {
        const Int = std.meta.Int(false, bits);
        inline for ([_]Ordering{.relaxed, .acquire, .release, .acq_rel, .seq_cst}) |ordering| {

            var value: Int = 0b10;
            std.testing.expectEqual(@as(u1, 0), Atomic.bitwise(&value, .get, 0, ordering));
            std.testing.expectEqual(@as(u1, 1), Atomic.bitwise(&value, .get, 1, ordering));   
        }
    }
}

test "Atomic.bitwise.set" {
    comptime var bits = std.meta.bitCount(usize);
    inline while (bits != 0 and bits >= std.meta.bitCount(u8)) : (bits >>= 1) {
        const Int = std.meta.Int(false, bits);
        inline for ([_]Ordering{.relaxed, .acquire, .release, .acq_rel, .seq_cst}) |ordering| {

            var value: Int = 0b00;
            std.testing.expectEqual(@as(u1, 0), Atomic.bitwise(&value, .set, 0, ordering));
            std.testing.expectEqual(@as(Int, 0b01), value);
            std.testing.expectEqual(@as(u1, 1), Atomic.bitwise(&value, .set, 0, ordering));
            std.testing.expectEqual(@as(Int, 0b01), value);
            std.testing.expectEqual(@as(u1, 0), Atomic.bitwise(&value, .set, 1, ordering));
            std.testing.expectEqual(@as(Int, 0b11), value);
        }
    }
}

test "Atomic.bitwise.reset" {
    comptime var bits = std.meta.bitCount(usize);
    inline while (bits != 0 and bits >= std.meta.bitCount(u8)) : (bits >>= 1) {
        const Int = std.meta.Int(false, bits);
        inline for ([_]Ordering{.relaxed, .acquire, .release, .acq_rel, .seq_cst}) |ordering| {

            var value: Int = 0b11;
            std.testing.expectEqual(@as(u1, 1), Atomic.bitwise(&value, .reset, 0, ordering));
            std.testing.expectEqual(@as(Int, 0b10), value);
            std.testing.expectEqual(@as(u1, 0), Atomic.bitwise(&value, .reset, 0, ordering));
            std.testing.expectEqual(@as(Int, 0b10), value);
            std.testing.expectEqual(@as(u1, 1), Atomic.bitwise(&value, .reset, 1, ordering));
            std.testing.expectEqual(@as(Int, 0b00), value);
        }
    }
}